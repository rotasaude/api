# Tamanho e passo da amostra do LIRAa (módulo 35a, ADR 0054; contrato §7;
# Q16, Q17). Puro: N, B e os parâmetros (VectorControl::Parameters) entram,
# o plano sai. Aritmética exata (Rational) para os tetos.
#   - faixas: standard liraa_standard_min ≤ N ≤ liraa_standard_max; half
#     liraa_half_min ≤ N < liraa_standard_min; census N < liraa_half_min.
#     Fora → :out_of_range (também sem quarteirão);
#   - standard e half (Q17: o half segue o manual de 2013, p.13, com os
#     quarteirões sorteados como no standard): n = ⌈base ÷ (1 + base ÷ N)⌉;
#     h = ⌈f · N ÷ B⌉ (imóveis por quarteirão, f = fração do modo); b = ⌈n ÷ h⌉;
#     k = max(1, ⌊B ÷ b⌋);
#   - census: todos (n = N, b = B, k = 1, f = 1);
#   - fração do modo: liraa_household_fraction (standard), a chave nova
#     liraa_half_household_fraction (half), 1 (census); o intervalo dos imóveis
#     é round(1 ÷ f) (standard 5, half 2, census 1), nunca constante.
# N já vem sem ponto estratégico (Q16(d)); quem conta é o Liraa::Draw.
module VectorControl
  module Liraa
    module Sample
      Plan = Data.define(:n, :h, :b, :k, :fraction, :interval)

      FRACTION_KEYS = { "standard" => "liraa_household_fraction", "half" => "liraa_half_household_fraction" }.freeze

      module_function

      # -> Plan | :out_of_range
      def plan(mode:, households_count:, blocks_count:, parameters:)
        big_n = households_count
        big_b = blocks_count
        return :out_of_range unless big_b.positive? && in_range?(mode, big_n, parameters)
        return :out_of_range if big_n.zero? && mode != "census"
        return Plan.new(n: big_n, h: Rational(big_n, big_b).ceil, b: big_b, k: 1, fraction: 1r, interval: 1) if mode == "census"

        fraction = fraction(mode, parameters)
        base = value(parameters, "liraa_base_sample")
        n = Rational(base * big_n, big_n + base).ceil
        h = [ (fraction * big_n / big_b).ceil, 1 ].max
        b = Rational(n, h).ceil
        Plan.new(n: n, h: h, b: b, k: [ 1, big_b / b ].max, fraction: fraction, interval: interval(fraction))
      end

      def in_range?(mode, big_n, parameters)
        standard_min = value(parameters, "liraa_standard_min")
        half_min = value(parameters, "liraa_half_min")
        case mode
        when "standard" then big_n.between?(standard_min, value(parameters, "liraa_standard_max"))
        when "half" then big_n >= half_min && big_n < standard_min
        when "census" then big_n >= 0 && big_n < half_min
        else false
        end
      end

      # Posições (1-based) dos quarteirões sorteados na lista ordenada: r, r+k, …
      # até b quarteirões ou o fim; census, todos.
      def block_positions(plan:, blocks_count:, random_start:)
        (0...plan.b).map { |step| random_start + (step * plan.k) }.take_while { |position| position <= blocks_count }
      end

      # Posições (1-based) dos imóveis do quarteirão de M imóveis: ⌈f · M⌉ (no
      # máximo M), um a cada `interval` a partir do 1º (Q16(b)); ao passar do
      # fim volta ao começo, e a posição já tomada cede à seguinte livre.
      def household_positions(plan:, households_count:)
        count = households_count
        return [] if count.zero?

        take = [ (plan.fraction * count).ceil, count ].min
        taken = []
        cursor = 0
        take.times do
          cursor %= count
          cursor = (cursor + 1) % count while taken.include?(cursor)
          taken << cursor
          cursor += plan.interval
        end
        taken.map { |index| index + 1 }
      end

      def fraction(mode, parameters)
        key = FRACTION_KEYS.fetch(mode)
        exact(parameters.fetch(key) { Parameters.defaults.fetch(key) })
      end

      def interval(fraction) = [ (1 / fraction).round, 1 ].max

      # Versão gravada antes de uma chave nova cai no padrão de fábrica.
      def value(parameters, key) = parameters.fetch(key) { Parameters.defaults.fetch(key) }

      def exact(number) = BigDecimal(number.to_s).to_r
    end
  end
end
