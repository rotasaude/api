#!/usr/bin/env ruby
# frozen_string_literal: true
# Inventário de ponteiros de ADR no apps/api. Rode da raiz do repo api:
#   ruby script/adr_pointer_inventory.rb > /tmp/adr-inventory.tsv
#
# encoding: "UTF-8" é obrigatório — os comentários são acentuados e o default
# externo do ambiente pode ser US-ASCII, o que faz o scan levantar
# ArgumentError: invalid byte sequence.
ROOTS = %w[app config db lib spec deploy].freeze
VALID = (1..15).freeze

paths = (ROOTS.flat_map { |r| Dir.glob("#{r}/**/*.{rb,yml,yaml,erb,rake,md}") } + Dir.glob("*.md"))
        .sort.uniq

puts %w[file line ref in_range context].join("\t")
paths.each do |path|
  File.readlines(path, encoding: "UTF-8").each_with_index do |line, i|
    line.scan(/ADR[-\s]?(\d{4})/).flatten.uniq.each do |num|
      puts [path, i + 1, "ADR-#{num}", VALID.cover?(num.to_i), line.strip].join("\t")
    end
  end
end
