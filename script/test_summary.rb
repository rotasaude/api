# Resumo curto de uma rodada do rspec para o bin/test: contagem, duração e uma
# linha por falha (arquivo:linha — 1ª linha da mensagem). O log completo fica no
# arquivo; quem pediu o teste recebe só isto. Ruby puro, sem Rails.
#
# Uso: ruby script/test_summary.rb <rspec.json> <run.log> <exit_code>
require "json"

module TestSummary
  MAX_FAILURES = 30
  LOG_TAIL = 20

  module_function

  def render(json_path:, log_path:, exit_code:)
    data = read_json(json_path)
    return not_run(log_path, "exit #{exit_code}") unless data

    s = data.fetch("summary")
    # Erro de carga (spec com erro de sintaxe, support quebrado, TestServerGuard):
    # o rspec ainda grava o JSON, com 0 exemplos — não pode sair como "0 falhas".
    if s["example_count"].to_i.zero? && s["errors_outside_of_examples_count"].to_i.positive?
      return not_run(log_path, "erro ao carregar, exit #{exit_code}")
    end

    lines = ["#{s['example_count']} exemplos, #{s['failure_count']} falhas, " \
             "#{s['pending_count']} pendentes em #{s['duration'].round(1)}s"]
    lines.concat(failure_lines(data.fetch("examples", [])))
    outside = s["errors_outside_of_examples_count"].to_i
    lines.push("erros fora de exemplo: #{outside}", *log_tail(log_path)) if outside.positive?
    lines << "log: #{log_path}"
    lines.join("\n")
  end

  def read_json(path)
    return unless File.exist?(path)

    body = File.read(path, encoding: "UTF-8")
    body.strip.empty? ? nil : JSON.parse(body)
  rescue JSON::ParserError
    nil
  end

  def failure_lines(examples)
    failures = examples.select { |e| e["status"] == "failed" }
    lines = failures.first(MAX_FAILURES).map do |e|
      message = e.dig("exception", "message").to_s.strip.lines.first.to_s.strip
      "#{e['file_path'].delete_prefix('./')}:#{e['line_number']} — #{message}"
    end
    extra = failures.size - MAX_FAILURES
    extra.positive? ? lines << "… +#{extra} (ver log)" : lines
  end

  def not_run(log_path, reason)
    ["suíte não rodou (#{reason})", *log_tail(log_path), "log: #{log_path}"].join("\n")
  end

  def log_tail(path)
    File.exist?(path) ? File.readlines(path, chomp: true, encoding: "UTF-8").last(LOG_TAIL) : ["(log ausente)"]
  end
end

if $PROGRAM_NAME == __FILE__
  json, log, code = ARGV
  puts TestSummary.render(json_path: json, log_path: log, exit_code: code)
end
