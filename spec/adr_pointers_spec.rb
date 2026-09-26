require "rails_helper"

# Guarda de numeração do corpus de ADRs. O v2 vai de 0001 a 0019; qualquer
# outro número é da numeração v1, que foi aposentada.
#
# Escopo desta guarda: ela pega ponteiro FORA da faixa. Ela NÃO pega um
# ADR-0009 que continuou querendo dizer o 0009 do v1 — números baixos existem
# nas duas numerações com sentidos diferentes. Contra essa classe o que vale é
# docs/adr/RECONCILIACAO-PONTEIROS.md (no repo docs) e a revisão.
RSpec.describe "ADR pointers" do
  ROOTS = %w[app config db lib spec deploy].freeze
  VALID_RANGE = (1..19).freeze
  SELF_PATH = "spec/adr_pointers_spec.rb"
  # Casa a forma compacta também: "ADR-0012/0013" carrega DOIS ponteiros, e um
  # regex que só lê o primeiro deixaria o segundo passar sem conferência.
  REF = %r{ADR[-\s]?\d{4}(?:/\d{4})*}

  def out_of_range
    Dir.chdir(Rails.root) do
      paths = (ROOTS.flat_map { |r| Dir.glob("#{r}/**/*.{rb,yml,yaml,erb,rake,md}") } +
               Dir.glob("*.md")).sort.uniq - [SELF_PATH]

      paths.flat_map do |path|
        File.readlines(path, encoding: "UTF-8").each_with_index.flat_map do |line, i|
          line.scan(REF).flat_map { |ref| ref.scan(/\d{4}/) }.uniq
              .reject { |num| VALID_RANGE.cover?(num.to_i) }
              .map { |num| "#{path}:#{i + 1} → ADR-#{num}" }
        end
      end
    end
  end

  it "only points at ADRs that exist in the v2 corpus (0001..0019)" do
    offenders = out_of_range
    expect(offenders).to eq([]),
      "#{offenders.size} ponteiro(s) fora do corpus v2:\n#{offenders.join("\n")}"
  end
end
