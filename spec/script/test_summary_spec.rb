require "json"
require "tmpdir"
require_relative "../../script/test_summary"

RSpec.describe TestSummary do
  around { |ex| Dir.mktmpdir { |dir| @dir = dir; ex.run } }

  let(:log_path) do
    File.join(@dir, "run.log").tap { |p| File.write(p, (1..30).map { |i| "linha #{i}" }.join("\n")) }
  end

  def json_file(summary:, examples: [])
    File.join(@dir, "run.json").tap do |p|
      File.write(p, JSON.generate("summary" => summary, "examples" => examples))
    end
  end

  def summary(examples: 1662, failures: 0, pending: 2, outside: 0, duration: 312.41)
    { "example_count" => examples, "failure_count" => failures, "pending_count" => pending,
      "errors_outside_of_examples_count" => outside, "duration" => duration }
  end

  def failed(file, line, message)
    { "status" => "failed", "file_path" => file, "line_number" => line,
      "exception" => { "message" => message } }
  end

  it "resume uma rodada verde em contagem, duração e caminho do log" do
    out = described_class.render(json_path: json_file(summary: summary), log_path: log_path, exit_code: 0)

    expect(out).to include("1662 exemplos, 0 falhas, 2 pendentes")
    expect(out).to include("em 312.4s")
    expect(out).to include("log: #{log_path}")
  end

  it "lista cada falha numa linha, só com a primeira linha da mensagem" do
    examples = [failed("./spec/x_spec.rb", 12, "expected 1, got 2\n  detalhe"),
                { "status" => "passed", "file_path" => "./spec/y_spec.rb", "line_number" => 3 }]
    out = described_class.render(json_path: json_file(summary: summary(failures: 1), examples: examples),
                                 log_path: log_path, exit_code: 1)

    expect(out).to include("spec/x_spec.rb:12 — expected 1, got 2")
    expect(out).not_to include("detalhe")
    expect(out).not_to include("y_spec")
  end

  it "corta em 30 falhas e manda o resto para o log" do
    examples = (1..35).map { |i| failed("./spec/x_spec.rb", i, "boom #{i}") }
    out = described_class.render(json_path: json_file(summary: summary(failures: 35), examples: examples),
                                 log_path: log_path, exit_code: 1)

    expect(out).to include("x_spec.rb:30 — boom 30")
    expect(out).not_to include("x_spec.rb:31 —")
    expect(out).to include("… +5 (ver log)")
  end

  it "diz que a suíte não rodou quando não há JSON, sem fingir zero falhas" do
    out = described_class.render(json_path: File.join(@dir, "ausente.json"), log_path: log_path, exit_code: 1)

    expect(out).to include("suíte não rodou (exit 1)")
    expect(out).to include("linha 30").and include("linha 11")
    expect(out).not_to include("linha 10\n")
    expect(out).not_to include("0 falhas")
  end

  it "trata JSON vazio como suíte que não rodou" do
    path = File.join(@dir, "vazio.json").tap { |p| File.write(p, "") }
    out = described_class.render(json_path: path, log_path: log_path, exit_code: 1)

    expect(out).to include("suíte não rodou (exit 1)")
  end

  it "lê JSON e log em UTF-8 mesmo com locale US-ASCII (shell do host sem LANG)" do
    File.write(log_path, "falhou: não encontrado\n")
    json = json_file(summary: summary(failures: 1, outside: 1), examples: [failed("./spec/x_spec.rb", 1, "esperava não nulo")])
    previous = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII
    out = described_class.render(json_path: json, log_path: log_path, exit_code: 1)

    expect(out).to include("esperava não nulo").and include("falhou: não encontrado")
  ensure
    Encoding.default_external = previous
  end

  it "mostra erros fora de exemplo com o fim do log" do
    out = described_class.render(json_path: json_file(summary: summary(examples: 0, outside: 1)),
                                 log_path: log_path, exit_code: 1)

    expect(out).to include("erros fora de exemplo: 1")
    expect(out).to include("linha 30")
  end
end
