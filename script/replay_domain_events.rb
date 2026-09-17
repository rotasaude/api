#!/usr/bin/env ruby
# frozen_string_literal: true
# Ferramenta de replay de domain_events. Ver ADR-0009.
# Uso (sempre via `bin/rails runner` para carregar a app):
#
#   bin/rails runner script/replay_domain_events.rb -- --dry-run
#   bin/rails runner script/replay_domain_events.rb -- --name=triagem.completed --since=2026-06-01
#   bin/rails runner script/replay_domain_events.rb -- --batch-size=200
#
# Idempotência por consumidor (ADR-0005) garante que jobs já consumidos
# silenciosamente pulam. Mesmo assim, --dry-run é mandatório antes de prod.

require "optparse"

options = {
  dry_run: false,
  name: nil,
  since: nil,
  until_at: nil,
  batch_size: 500,
  sleep_between: 0.2
}

OptionParser.new do |opts|
  opts.on("--dry-run")             { options[:dry_run] = true }
  opts.on("--name=NAME")           { |v| options[:name] = v }
  opts.on("--since=ISO8601")       { |v| options[:since] = Time.parse(v) }
  opts.on("--until=ISO8601")       { |v| options[:until_at] = Time.parse(v) }
  opts.on("--batch-size=N", Integer) { |v| options[:batch_size] = v }
  opts.on("--sleep=SECONDS", Float)  { |v| options[:sleep_between] = v }
end.parse!(ARGV)

scope = DomainEvent.order(:occurred_at, :id)
scope = options[:name] ? scope.where(name: options[:name]) : scope.pending
scope = scope.where("occurred_at >= ?", options[:since])    if options[:since]
scope = scope.where("occurred_at <= ?", options[:until_at]) if options[:until_at]

total = scope.count
puts "[replay] target: #{total} event(s)"
puts "[replay] filters: name=#{options[:name].inspect} since=#{options[:since]} until=#{options[:until_at]}"
puts "[replay] mode: #{options[:dry_run] ? "DRY-RUN" : "EXECUTE"}"
puts "[replay] batch_size=#{options[:batch_size]} sleep=#{options[:sleep_between]}s"

if total.zero?
  puts "[replay] nothing to do"
  exit 0
end

enqueued = 0
scope.find_each(batch_size: options[:batch_size]) do |event|
  bindings = Events.bindings[event.name]
  if bindings.empty?
    puts "[replay] skip event=#{event.id} name=#{event.name} (no bindings)"
    next
  end

  if options[:dry_run]
    puts "[replay] would redispatch event=#{event.id} name=#{event.name} -> #{bindings.map(&:name).join(", ")}"
  else
    Events.redispatch(event)
    enqueued += 1
    sleep(options[:sleep_between]) if (enqueued % options[:batch_size]).zero?
  end
end

puts "[replay] done. #{options[:dry_run] ? "would enqueue" : "enqueued"} #{enqueued}/#{total}"
