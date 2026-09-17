#!/usr/bin/env ruby
# frozen_string_literal: true
# Recompõe dashboard_metrics a partir das tabelas-fonte. Ver ADR-0007.
# Execute via: bin/rails runner script/rebuild_dashboard_metrics.rb [-- --dry-run]
#
# Idempotente: TRUNCATE + INSERT. Roda também pelo RebuildDashboardMetricsJob
# nightly (recurring.yml).

require "optparse"

options = { dry_run: false, since: nil }
OptionParser.new do |opts|
  opts.on("--dry-run")          { options[:dry_run] = true }
  opts.on("--since=ISO8601")    { |v| options[:since] = Time.parse(v) }
end.parse!(ARGV)

scope = Triagem.where(status: :completed)
scope = scope.where("completed_at >= ?", options[:since]) if options[:since]

puts "[rebuild_dashboard] mode=#{options[:dry_run] ? "DRY-RUN" : "EXECUTE"} target=#{scope.count} triagens"

if options[:dry_run]
  puts "[rebuild_dashboard] would TRUNCATE dashboard_metrics"
  puts "[rebuild_dashboard] would recompute from #{scope.count} completed triagens"
  exit 0
end

ApplicationRecord.transaction do
  DashboardMetric.delete_all
  puts "[rebuild_dashboard] cleared"

  buffer = Hash.new(0)   # [municipality_id, dimension, period, key] => count

  scope.find_each(batch_size: 1000) do |triagem|
    municipality_id = triagem.conversation.municipality_id
    next unless municipality_id
    date = triagem.completed_at.to_date.iso8601

    buffer[[municipality_id, "triagens_by_tier", date, triagem.tier.to_s]] += 1
    buffer[[municipality_id, "triagens_total",   date, "total"]] += 1
    buffer[[municipality_id, "priority_distribution", date, triagem.priority.to_s]] += 1
  end

  rows = buffer.map do |(municipality_id, dimension, period, key), value|
    {
      municipality_id: municipality_id,
      dimension: dimension,
      period: period,
      key: key,
      value: value,
      updated_at: Time.current
    }
  end

  DashboardMetric.insert_all(rows) if rows.any?
  puts "[rebuild_dashboard] inserted #{rows.size} rows"
end
