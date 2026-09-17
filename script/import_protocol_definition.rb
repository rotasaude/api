#!/usr/bin/env ruby
# frozen_string_literal: true
# Importa uma definição de protocolo. Valida + insere como draft (default) ou
# ativa direto. Ver ADR-0016.
#
# Uso (sempre via rails runner para ter AR + Protocols::):
#   bin/rails runner script/import_protocol_definition.rb -- path/to/file.yml
#   bin/rails runner script/import_protocol_definition.rb -- path/to/file.yml --activate
#   bin/rails runner script/import_protocol_definition.rb -- file.yml --municipality=<uuid>

require "optparse"
require "yaml"
require "json"
require "pathname"

options = { activate: false, municipality_id: nil }
parser = OptionParser.new do |opts|
  opts.on("--activate")            { options[:activate] = true }
  opts.on("--municipality=ID")     { |v| options[:municipality_id] = v }
end
remaining = parser.parse(ARGV)
path = remaining[0] or abort("usage: import_protocol_definition.rb <file> [--activate] [--municipality=ID]")

file = Pathname(path)
abort("not found: #{path}") unless file.file?

content = file.read
definition =
  case file.extname.downcase
  when ".yml", ".yaml" then YAML.safe_load(content, permitted_classes: [Symbol])
  when ".json"         then JSON.parse(content)
  else                       abort("unsupported extension: #{file.extname}")
  end

result = Protocols::Validator.call(definition)
unless result.valid?
  warn "[import] INVALID  #{path}"
  result.errors.each { |e| warn "  - #{e}" }
  exit 1
end

name = definition.fetch("name")
version = definition.fetch("version")

ApplicationRecord.transaction do
  if ProtocolDefinition.exists?(name: name, version: version, municipality_id: options[:municipality_id])
    abort("[import] already exists: name=#{name} version=#{version} municipality=#{options[:municipality_id]}")
  end

  record = ProtocolDefinition.create!(
    name: name,
    version: version,
    municipality_id: options[:municipality_id],
    definition: definition,
    status: "draft"
  )
  puts "[import] created  draft  id=#{record.id} #{name}@#{version}"

  if options[:activate]
    ProtocolDefinition
      .where(name: name, municipality_id: options[:municipality_id], status: "active")
      .update_all(status: "retired", retired_at: Time.current)
    record.update!(status: "active", activated_at: Time.current)
    puts "[import] activated id=#{record.id} #{name}@#{version}"
  end
end
