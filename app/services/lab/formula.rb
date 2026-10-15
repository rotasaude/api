# Fórmula de componente calculado (spec §4; Valores fixados 3): números,
# chaves permitidas, + - * / e parênteses. Sem eval: shunting-yard para RPN
# na versão e cálculo com BigDecimal na digitação. Divisão por zero ou
# componente ausente = sem valor (nil).
module Lab
  module Formula
    TOKEN = %r{\A\s*(?:(\d+(?:\.\d+)?)|([a-z][a-z0-9_]{0,39})|([-+*/()]))\s*}
    PRECEDENCE = { "+" => 1, "-" => 1, "*" => 2, "/" => 2 }.freeze
    MAX = 200

    module_function

    def compile(text, allowed:)
      tokens = tokenize(text)
      return nil unless tokens && well_formed?(tokens) && tokens.all? { |kind, v| kind != :var || allowed.include?(v) }

      to_rpn(tokens)
    end

    def evaluate(rpn, values:)
      stack = []
      rpn.each do |kind, v|
        case kind
        when :num then stack << v
        when :var then (value = values[v]) ? stack << value : (return nil)
        when :op
          right, left = stack.pop, stack.pop
          return nil if v == "/" && right.zero?

          stack << left.public_send(v, right)
        end
      end
      stack.size == 1 ? stack.first : nil
    end

    def tokenize(text)
      return nil unless text.is_a?(String) && text.strip.length.between?(1, MAX)

      rest = text.strip
      tokens = []
      until rest.empty?
        match = rest.match(TOKEN) or return nil
        tokens << if match[1] then [ :num, BigDecimal(match[1]) ]
                  elsif match[2] then [ :var, match[2] ]
                  elsif "()".include?(match[3]) then [ :paren, match[3] ]
                  else [ :op, match[3] ]
                  end
        rest = match.post_match
      end
      tokens
    end

    # Operando e operador alternados; parênteses equilibrados; sem unário.
    def well_formed?(tokens)
      expect_operand = true
      depth = 0
      tokens.each do |kind, v|
        if kind == :paren && v == "("
          return false unless expect_operand

          depth += 1
        elsif kind == :paren
          return false if expect_operand || depth.zero?

          depth -= 1
        elsif kind == :op
          return false if expect_operand

          expect_operand = true
        else
          return false unless expect_operand

          expect_operand = false
        end
      end
      !expect_operand && depth.zero?
    end

    def to_rpn(tokens)
      output = []
      ops = []
      tokens.each do |kind, v|
        case kind
        when :num, :var then output << [ kind, v ]
        when :op
          output << ops.pop while ops.last && ops.last[0] == :op && PRECEDENCE[ops.last[1]] >= PRECEDENCE[v]
          ops << [ :op, v ]
        when :paren
          if v == "(" then ops << [ :paren, v ]
          else
            output << ops.pop until ops.last[0] == :paren
            ops.pop
          end
        end
      end
      output.concat(ops.reverse)
    end
    private_class_method :tokenize, :well_formed?, :to_rpn
  end
end
