import { rerankCandidates } from '../src/server/reranker.ts';
import type { BenchmarkMode, Searcher, SearchHit } from './honest-recall.ts';

const RERANK_RETRIEVE_K = 100;
const RERANK_MODEL = 'bge-reranker-v2-m3';

export type RerankOptions = { enabled?: boolean; url?: string; timeoutMs?: number };
export type RerankStage = { enabled: boolean; model?: string; retrieve_k?: number; applied: boolean; fallback_reason?: string };

export function rerankStage(enabled: boolean): RerankStage {
  return enabled ? { enabled: true, model: RERANK_MODEL, retrieve_k: RERANK_RETRIEVE_K, applied: false } : { enabled: false, applied: false };
}

export async function searchWithOptionalRerank(input: {
  searcher: Searcher;
  query: string;
  topK: number;
  mode: BenchmarkMode;
  model: string;
  rerank?: RerankOptions;
  stage: RerankStage;
}): Promise<SearchHit[]> {
  if (!input.rerank?.enabled) {
    return (await input.searcher(input)).slice(0, input.topK);
  }

  const candidates = await input.searcher({ ...input, topK: Math.max(RERANK_RETRIEVE_K, input.topK) });
  const reranked = await rerankCandidates({
    query: input.query,
    candidates,
    getText: hitText,
    topK: input.topK,
    url: input.rerank.url,
    timeoutMs: input.rerank.timeoutMs,
  });
  input.stage.applied ||= reranked.reranked;
  if (reranked.fallbackReason) input.stage.fallback_reason = reranked.fallbackReason;
  return reranked.results.slice(0, input.topK);
}

function hitText(hit: SearchHit): string {
  return hit.content || hit.text || hit.title || hit.source_file || hit.sourceFile || hit.id;
}
