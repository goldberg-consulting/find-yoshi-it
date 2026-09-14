"""Compare local embeddings and sampled ANN recall; never upload documents or queries."""
import argparse, json, sqlite3, struct, time, os
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
os.environ['DO_NOT_TRACK'] = '1'
import numpy as np
from fastembed import TextEmbedding

parser = argparse.ArgumentParser()
parser.add_argument('--fixture', required=True)
parser.add_argument('--apple', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--database')
args = parser.parse_args()
fixture, apple = json.load(open(args.fixture)), json.load(open(args.apple))
texts = [c['text'] for c in fixture['cases']] + fixture['distractors']
queries = [c['query'] for c in fixture['cases']]
def unit(x):
    x = np.asarray(x, dtype=np.float32)
    return x / np.maximum(np.linalg.norm(x, axis=-1, keepdims=True), 1e-12)
def evaluate(docs, qs):
    ranked = np.argsort(-(unit(qs) @ unit(docs).T), axis=1)
    ranks = [int(np.where(ranked[i] == i)[0][0]) + 1 for i in range(len(qs))]
    return {'top1': sum(r == 1 for r in ranks)/len(ranks), 'top5': sum(r <= 5 for r in ranks)/len(ranks),
            'mrr': float(np.mean([1/r for r in ranks])), 'ranks': ranks}
report = {'fixture': fixture['description'], 'queries': len(queries), 'documents': len(texts),
          'apple': {'model': apple['model'], **evaluate(apple['documents'], apple['queries'])}}
model = TextEmbedding(model_name='BAAI/bge-small-en-v1.5', cache_dir='/private/tmp/findanything-embedding-models', threads=4)
start = time.monotonic()
docs = list(model.passage_embed(texts))
qs = list(model.query_embed(queries))
report['bge'] = {'model': 'BAAI/bge-small-en-v1.5', 'embeddingSeconds': time.monotonic()-start, **evaluate(docs, qs)}
if args.database:
    db = sqlite3.connect(f'file:{args.database}?mode=ro', uri=True)
    low, high = db.execute('select min(passage_id),max(passage_id) from vectors where model=?', [apple['model']]).fetchone()
    selected = {}
    for point in np.linspace(low, high, 4096).astype(int):
        row = db.execute('select passage_id,vector from vectors where passage_id>=? and model=? order by passage_id limit 1', [int(point),apple['model']]).fetchone()
        if row: selected[row[0]] = row[1]
    ids = sorted(selected)
    vectors, buckets = [], []
    for pid in ids:
        blob = selected[pid]
        assert blob[:4] == b'FAV1'
        dim, scale = struct.unpack('<If', blob[4:12])
        vectors.append(np.frombuffer(blob[12:],dtype=np.int8).astype(np.float32) * scale)
        buckets.append(set(r[0] for r in db.execute('select bucket from vector_buckets where passage_id=?',[pid])))
    scores = unit(apple['queries']) @ unit(vectors).T
    recalls = []
    for index, keys in enumerate(apple['queryBuckets']):
        lookup = set(keys)
        hits = np.array([len(lookup & b) for b in buckets])
        candidates = sorted(np.where(hits > 0)[0],key=lambda j:(-hits[j],ids[j]))[:1200]
        exact = set(np.argsort(-scores[index])[:10])
        recovered = set(sorted(candidates,key=lambda j:-scores[index,j])[:10])
        recalls.append(len(exact & recovered)/10)
    report['sampled_lsh'] = {'sampleVectors': len(ids), 'sampling': 'Evenly spaced passage IDs; not a full-corpus or random-sample estimate', 'candidateLimit':1200, 'meanRecallAt10': float(np.mean(recalls)), 'perQuery':recalls}
with open(args.output,'w') as out: json.dump(report,out,indent=2)
print(json.dumps(report,indent=2))
