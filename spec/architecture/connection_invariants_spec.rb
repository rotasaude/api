require "rails_helper"

# Guardas do modelo de conexão (spec 2026-09-12-banco-por-cidade-design).
#
# O invariante do connects_to não é estilo: medido no spike 1, re-chamar
# connects_to sob tráfego causou 171.620 interrupções em cidades já ativas.
RSpec.describe "Connection invariants" do
  SOURCE_ROOTS = %w[app lib config].freeze
  SELF_PATH = "spec/architecture/connection_invariants_spec.rb"

  def source_files
    Dir.chdir(Rails.root) do
      SOURCE_ROOTS.flat_map { |r| Dir.glob("#{r}/**/*.rb") }.sort - [SELF_PATH]
    end
  end

  # `connects_to` aparece em prosa nos comentários que documentam este mesmo
  # invariante (ver app/models/city_connection.rb) — uma guarda que não
  # distingue código de comentário forçaria apagar essa explicação só para
  # passar no CI. Considera-se apenas linhas cujo primeiro caractere
  # não-espaço não é "#".
  def code_lines(lines)
    lines.each_with_index.reject { |line, _| line.strip.start_with?("#") }
  end

  it "only calls connects_to from an abstract class body" do
    offenders = Dir.chdir(Rails.root) do
      source_files.flat_map do |path|
        lines = File.readlines(path, encoding: "UTF-8")
        real_connects_to = code_lines(lines).select { |l, _| l.include?("connects_to") }
        next [] if real_connects_to.empty?
        next [] if lines.any? { |l| l.match?(/self\.abstract_class\s*=\s*true/) }

        real_connects_to.map { |_, i| "#{path}:#{i + 1}" }
      end
    end

    expect(offenders).to eq([]),
      "connects_to fora de classe abstrata (use CityConnection.ensure_pool):\n#{offenders.join("\n")}"
  end

  it "never calls connects_to on CityRecord from outside its own class body" do
    offenders = Dir.chdir(Rails.root) do
      (source_files - ["app/models/city_record.rb"]).select do |path|
        File.read(path, encoding: "UTF-8").match?(/CityRecord\.connects_to/)
      end
    end

    expect(offenders).to eq([]),
      "re-chamar connects_to derruba cidades em voo — use CityConnection.ensure_pool:\n#{offenders.join("\n")}"
  end

  it "declares connects_to exactly once in CityRecord" do
    expect(CityRecord.abstract_class?).to be(true)

    source = File.read(Rails.root.join("app/models/city_record.rb"), encoding: "UTF-8")
    occurrences = source.scan(/^\s*connects_to\b/).size

    expect(occurrences).to eq(1),
      "CityRecord precisa de exatamente um connects_to: zero quebra connected_to " \
      "(NotImplementedError), mais de um reconstrói o mapa de shards."
  end

  it "registers cities through establish_connection, not connects_to" do
    lines = File.readlines(Rails.root.join("app/models/city_connection.rb"), encoding: "UTF-8")
    code = code_lines(lines).map { |l, _| l }.join

    expect(code).to match(/establish_connection/)
    expect(code).not_to match(/connects_to/)
  end

  it "keeps the platform database free of citizen data tables" do
    citizen_tables = %w[conversations triages inbound_messages outbound_messages
                        consents report_snapshots].freeze
    present = PlatformRecord.connection.tables & citizen_tables

    expect(present).to eq([]),
      "tabelas de dado de cidadão no banco de plataforma: #{present.join(', ')}"
  end
end
