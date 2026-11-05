# Varredura de fonte das guardas de invariantes (eventos, log): as chamadas
# `DomainEvents.publish(` e `logger.*(` são multilinha, e o grep de uma linha
# devolve lista incompleta sem erro. Aqui a chamada inteira é lida por
# balanceamento de parênteses e dividida nos argumentos de nível zero.
# Auto-testes em spec/support/source_scan_spec.rb.
module SourceScan
  # [[arquivo, corpo]] de cada chamada `opening`...`)` (corpo inteiro, multilinha).
  def balanced_calls(opening, files)
    files.flat_map do |file|
      src = File.read(file)
      src.enum_for(:scan, opening).map do
        i = start = Regexp.last_match.end(0)
        depth = 1
        while depth.positive? && i < src.length
          depth += 1 if src[i] == "("
          depth -= 1 if src[i] == ")"
          i += 1
        end
        [ file, src[start...(i - 1)] ]
      end
    end
  end

  # Divide nas vírgulas de nível zero.
  def top_level_args(body)
    args = [ +"" ]
    depth = 0
    body.each_char do |c|
      depth += 1 if "([{".include?(c)
      depth -= 1 if ")]}".include?(c)
      if c == "," && depth.zero?
        args << +""
      else
        args.last << c
      end
    end
    args.map(&:strip).reject(&:empty?)
  end

  # O arquivo sem as linhas de comentário (um nome citado em comentário não conta como declarado).
  def code_lines(path) = File.readlines(path).reject { |l| l.strip.start_with?("#") }.join
end

RSpec.configure { |c| c.include SourceScan }
