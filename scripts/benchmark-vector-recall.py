"""Compare packed scoring and legacy ANN recall locally. Outputs aggregate metrics only.
Build the scorer with: clang -O3 -dynamiclib Sources/VectorMath/VectorMath.c
  -I Sources/VectorMath/include -o /tmp/libvector-math.dylib
"""
import argparse, ctypes, json, math, sqlite3, struct
from pathlib import Path
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument('--database', required=True)
parser.add_argument('--apple', required=True)
parser.add_argument('--library', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
queries = json.loads(Path(args.apple).read_text())
db = sqlite3.connect(Path(args.database).resolve().as_uri() + '?mode=ro', uri=True)
count = db.execute('select count(*) from vectors where model=?', [queries['model']]).fetchone()[0]
stride = max(1, count // 4096)
rows = db.execute('select passage_id,vector from vectors where model=? and passage_id % ?=0 order by passage_id limit 4096', [queries['model'], stride]).fetchall()
if not rows: raise SystemExit('No vectors for this model')
ids = [row[0] for row in rows]
blobs = [row[1] for row in rows]
vectors = []
for blob in blobs:
    if blob[:4] != b'FAV1': raise ValueError('Unrecognized vector format')
    dim, scale = struct.unpack('<If', blob[4:12])
    vector = np.frombuffer(blob[12:], dtype=np.int8).astype(np.float64) * scale
    if len(vector) != dim: raise ValueError('Wrong vector dimension')
    vectors.append(vector / np.linalg.norm(vector))
matrix = np.array(vectors)
lib = ctypes.CDLL(args.library)
score = lib.fy_packed_cosine
score.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_float), ctypes.c_size_t]
score.restype = ctypes.c_double
max_error = 0.0
exact_recalls, ann_recalls = [], []
buckets = [set(x[0] for x in db.execute('select bucket from vector_buckets where passage_id=?', [pid])) for pid in ids]
for q, query_buckets in zip(queries['queries'], queries['queryBuckets']):
    q = np.array(q, dtype=np.float32)
    ref = matrix @ (q.astype(np.float64) / np.linalg.norm(q.astype(np.float64)))
    packed = np.array([score(blob, len(blob), q.ctypes.data_as(ctypes.POINTER(ctypes.c_float)), len(q)) for blob in blobs])
    max_error = max(max_error, float(np.max(np.abs(ref-packed))))
    k = min(10, len(rows))
    threshold = np.sort(ref)[-k]
    chosen = np.argsort(-packed)[:k]
    exact_recalls.append(float(np.mean(ref[chosen] >= threshold-1e-6)))
    keys = set(query_buckets)
    hits = [len(keys & b) for b in buckets]
    candidates = sorted((i for i,h in enumerate(hits) if h), key=lambda i:(-hits[i],ids[i]))[:1200]
    chosen = sorted(candidates, key=lambda i:(-ref[i],ids[i]))[:k]
    ann_recalls.append(sum(ref[i] >= threshold-1e-6 for i in chosen)/k)
report = {'sampleVectors':len(rows),'sampling':'Deterministic passage-ID stride; sampled index, not full corpus recall',
          'queries':len(queries['queries']),'maxCosineError':max_error,
          'packedRecallAt10':float(np.mean(exact_recalls)), 'legacyLSHRecallAt10':float(np.mean(ann_recalls)),
          'tieTolerance':1e-6,'passed':max_error<1e-5 and min(exact_recalls)>=0.99}
Path(args.output).write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
