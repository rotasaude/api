#!/usr/bin/env ruby
# frozen_string_literal: true
# Lint offline de uma definição de protocolo. Ver ADR-0013 e ADR-0016.
# Roda SEM Rails — só precisa do motor puro em app/protocols/.
#
# Uso:
#   ruby script/validate_protocol_definition.rb path/to/definition.yml
#   ruby script/validate_protocol_definition.rb path/to/definition.json
#
# Sai com 0 se válido, 1 com lista de erros se inválido.

require "yaml"
require "json"
require "set"
require "pathname"

path = ARGV[0] or abort("usage: validate_protocol_definition.rb <file>")
file = Pathname(path)
abort("not found: #{path}") unless file.file?

content = file.read
definition =
  case file.extname.downcase
  when ".yml", ".yaml" then YAML.safe_load(content, permitted_classes: [Symbol])
  when ".json"         then JSON.parse(content)
  else                       abort("unsupported extension: #{file.extname}")
  end

# Carrega só o motor puro — sem Rails, sem AR.
protocols_root = File.expand_path("../app/protocols", __dir__)
%w[step.rb outcome.rb scoring/weighted.rb scoring/decision_table.rb scoring.rb validator.rb].each do |f|
  require File.join(protocols_root, f)
end

result = Protocols::Validator.call(definition)

if result.valid?
  puts "[validate] OK  #{path}"
  exit 0
else
  warn "[validate] INVALID  #{path}"
  result.errors.each { |e| warn "  - #{e}" }
  exit 1
end
