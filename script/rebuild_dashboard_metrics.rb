#!/usr/bin/env ruby
# frozen_string_literal: true
# Recompõe dashboard_metrics a partir das tabelas-fonte, em todas as cidades.
# Ver ADR-0010 e ADR-0022.
# Execute via: bin/rails runner script/rebuild_dashboard_metrics.rb [-- --since=AAAA-MM-DD]
#
# Só um atalho manual para o RebuildDashboardMetricsJob (o mesmo que roda toda
# madrugada pelo recurring.yml): a regra do que apaga e recria mora no job.

require "optparse"

options = {}
OptionParser.new do |opts|
  opts.on("--since=AAAA-MM-DD") { |v| options[:since] = v }
end.parse!(ARGV)

RebuildDashboardMetricsJob.perform_now(**options)
puts "[rebuild_dashboard] done#{" since #{options[:since]}" if options[:since]}"
