# Runs every demo query through the plugin's real retrieval (KnowledgeRetrieval.search)
# under several settings and prints two tables: the raw first stage per query (cosine vs.
# reranker score) and a scorecard per configuration. Read-only except for the AI request
# log (kb_retrieve / kb_rerank rows in the AI statistics). See README.md in this directory.
#
# Uses the central KB settings (embeddings + reranker endpoint/model) and overrides only
# the retrieval knobs under test. Override the list with THRESHOLDS="0.05,0.1,0.2".
require 'json'

dir     = ENV['DEMO_DIR'] || '/demo'
data    = JSON.parse(File.read(File.join(dir, 'dataset.json')))
project = Project.find_by!(:identifier => data['project']['identifier'])
qissue  = Issue.find_by!(:project_id => project.id, :subject => 'Demo query ticket')
subject_key  = data['entries'].to_h { |e| [e['subject'], e['key']] }
key_by_issue = Issue.where(:project_id => project.id).pluck(:id, :subject)
                    .to_h { |id, subj| [id, subject_key[subj]] }
base = Setting.plugin_redmine_expert_helpdesk.merge('kb_top_k' => '3', 'kb_min_results' => '1')
KR   = RedmineExpertHelpdesk::KnowledgeRetrieval

rclient = RedmineExpertHelpdesk::AiClient.new(base.merge('kb_rerank_enabled' => '1'))
abort 'Reranker is not configured (kb_rerank_model / endpoint / key).' unless rclient.rerank_configured?
store = RedmineExpertHelpdesk::KnowledgeStore.for(base)

puts "Embeddings: #{rclient.embed_model} / reranker: #{rclient.rerank_model}"
puts
puts '== First stage per query (top 5 by cosine; * = correct entry) =='
data['queries'].each do |q|
  hits = store.search(project.id, rclient.embed(q['text']), 20)
  rows = rclient.rerank(q['text'], hits.map { |h| h[:payload]['problem'] })
  rr   = rows.to_h { |r| [r[:index], r[:score]] }
  rank = rows.each_with_index.to_h { |r, i| [r[:index], i + 1] }
  puts "#{q['id']}  #{q['gold'].empty? ? '(no correct entry)' : "correct: #{q['gold'].join(', ')}"}"
  hits.first(5).each_with_index do |h, i|
    key = key_by_issue[h[:payload]['issue_id']]
    printf("   %s cos#%d %-18s cosine %.3f  rerank %.4f (rerank #%d)\n",
           q['gold'].include?(key) ? '*' : ' ', i + 1, key, h[:score], rr[i].to_f, rank[i])
  end
end

thresholds = (ENV['THRESHOLDS'] || '0.01,0.02,0.05,0.07,0.1,0.2,0.3,0.5').split(',').map(&:strip)
configs = [
  ['vector only, kb_min_score 0.5', { 'kb_rerank_enabled' => '0', 'kb_min_score' => '0.5' }],
  ['vector only, kb_min_score 0.6', { 'kb_rerank_enabled' => '0', 'kb_min_score' => '0.6' }]
] + thresholds.map do |m|
  ["rerank, kb_rerank_min_score #{m}", { 'kb_rerank_enabled' => '1', 'kb_rerank_min_score' => m }]
end

answerable = data['queries'].count { |q| q['gold'].any? }
unanswerable = data['queries'].size - answerable
puts
puts "== Scorecard (top_k 3; #{answerable} answerable + #{unanswerable} unanswerable queries) =="
printf("%-36s %8s %8s %12s %14s\n", 'configuration', 'top-1 ok', 'found', 'other hits', 'false alarms')
configs.each do |label, over|
  s = base.merge(over)
  client = RedmineExpertHelpdesk::AiClient.new(s)
  top1 = found = extra = false_alarm = 0
  data['queries'].each do |q|
    keys = KR.search(qissue, s, client, q['text']).map { |h| key_by_issue[h[:payload]['issue_id']] }
    if q['gold'].any?
      top1  += 1 if keys.first && q['gold'].include?(keys.first)
      found += 1 if (keys & q['gold']).any?
      extra += (keys - q['gold']).size
    elsif keys.any?
      false_alarm += 1
    end
  end
  printf("%-36s %8s %8s %12d %14s\n", label, "#{top1}/#{answerable}", "#{found}/#{answerable}",
         extra, "#{false_alarm}/#{unanswerable}")
end
