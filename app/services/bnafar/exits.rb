# Saídas do dia R (módulo 27b; Valores 5 e 6; Q13, Q14; Review Focus 1): os
# movimentos negativos CRIADOS em R (`from...to`) nos locais dos domínios
# ligados, fora dos ignorados (dispensação, desfazer da abertura) e sem link.
# O `recorded_at` não conta: a aplicação de R sincronizada em R+1 vai na remessa
# de R+1, nunca num dia já enviado, com `dataSaida` do dia em que foi criada.
#
# Estornos de uso direto (`*_reversal`, R1):
#   - o original do mesmo documento e lote criado no mesmo dia, ainda sem link,
#     é compensado antes do envio (a soma zera: nada sai; sobra parcial sai com
#     o que sobrou);
#   - o original já ligado vira Reversal(movement:, original_link:): a Task 11
#     decide `deletion` (DELETE do aceito na janela) ou `late_reversal` (Q14);
#   - o original nunca ligado (anterior ao envio, ou pendente) não vira nada: a
#     fotografia seguinte já corrige o saldo.
#
# Leitura pura: `domains` e o intervalo chegam calculados; `day` só identifica
# R. -> { exits: [Row], reversals: [Reversal] }. Na Row, `exit_type` nil =
# pendência `exit_type_missing`; `destination` nil = destino sem CNES
# (`location_without_cnes`); `quantity` nil = fração (`fractional_balance`).
module Bnafar
  module Exits
    Row = Data.define(:movement, :cnes, :type, :exit_type, :destination, :lot, :quantity)
    Reversal = Data.define(:movement, :original_link)

    # Estorno -> [tipo do original, coluna do documento].
    REVERSAL_OF = {
      "immunization_reversal" => [ "immunization", :immunization_id ],
      "vector_application_reversal" => [ "vector_application", :vector_inspection_measure_id ],
      "animal_vaccination_reversal" => [ "animal_vaccination", :rabies_vaccination_id ]
    }.freeze
    TRANSFER = "S-T".freeze
    INCLUDES = [ { stock_location: :health_unit }, { stock_lot: :vector_product }, :stock_adjustment, :stock_external_exit,
                 { stock_transfer: { to_location: :health_unit } } ].freeze

    module_function

    def call(day:, domains:, from:, to:)
      raise ArgumentError, "day is required" if day.nil?

      kinds = Snapshot.location_kinds(domains)
      return { exits: [], reversals: [] } if kinds.empty?

      movements = candidates(kinds, from, to)
      reversals, outgoing = movements.partition { |movement| REVERSAL_OF.key?(movement.kind) }
      net = outgoing.to_h { |movement| [ movement.id, movement.quantity.to_d ] }
      found = reversals.filter_map { |reversal| compensate(reversal, outgoing, net) }

      rows = outgoing.filter_map do |movement|
        quantity = -net.fetch(movement.id)
        next unless quantity.positive?

        row(movement, quantity)
      end
      { exits: rows, reversals: found }
    end

    # Reenvio e correção (Task 12): as linhas dos movimentos JÁ ligados a um
    # registro, com o dado de hoje (lote, CNES, destino) e a quantidade que foi
    # enviada (`quantities`: movimento → inteiro na unidade BNAFAR; a conta da
    # compensação parcial do dia não se refaz). Movimento que não é mais saída
    # (tipo ignorado) fica de fora. -> [Row]
    def reload(movements:, quantities:)
      found = StockMovement.where(id: Array(movements).map { |movement| movement.respond_to?(:id) ? movement.id : movement })
                           .includes(*INCLUDES).order(:created_at, :id).to_a
      found.filter_map { |movement| row(movement, movement.quantity.to_d.abs, converted: quantities[movement.id]) }
    end

    def candidates(kinds, from, to)
      StockMovement.joins(:stock_location).where(stock_locations: { kind: kinds })
                   .where(stock_movements: { created_at: from...to })
                   .where("stock_movements.quantity < 0 OR stock_movements.kind IN (?)", REVERSAL_OF.keys)
                   .where.not(kind: ExitTypes::IGNORED)
                   .where.not(id: BnafarMovementLink.select(:stock_movement_id))
                   .includes(*INCLUDES).order(:created_at, :id).to_a
    end

    # O estorno compensa o original do mesmo dia (mexe em `net`) ou vira
    # Reversal do original já ligado. -> Reversal | nil
    def compensate(reversal, outgoing, net)
      kind, column = REVERSAL_OF.fetch(reversal.kind)
      document = reversal[column]
      same_day = outgoing.find do |movement|
        movement.kind == kind && movement[column] == document && movement.stock_lot_id == reversal.stock_lot_id &&
          movement.stock_location_id == reversal.stock_location_id && net.fetch(movement.id).negative?
      end
      if same_day
        net[same_day.id] += reversal.quantity.to_d
        return nil
      end

      link = BnafarMovementLink.joins(:stock_movement).where(kind: "exit")
                               .find_by(stock_movements: { kind: kind, column => document, stock_lot_id: reversal.stock_lot_id,
                                                           stock_location_id: reversal.stock_location_id })
      link && Reversal.new(movement: reversal, original_link: link)
    end

    def row(movement, quantity, converted: nil)
      location = movement.stock_location
      lot = movement.stock_lot
      code = ExitTypes.for(movement, adjustment: movement.stock_adjustment, external_exit: movement.stock_external_exit)
      return nil if code.is_a?(Symbol) # :ignored, :reversal, :not_exit

      cnes = location.bnafar_cnes
      Row.new(movement: movement, cnes: cnes, type: LocationTypes.for(location), exit_type: code,
              destination: destination(movement, code, cnes), lot: lot, quantity: converted || Units.to_bnafar(lot, quantity))
    end

    # Valor 5 (Q13): S-T → o CNES do local de destino; saída externa → o destino
    # informado; o resto → o próprio estabelecimento.
    def destination(movement, code, cnes)
      return movement.stock_external_exit.destination_code if movement.kind == "external_exit"
      return movement.stock_transfer&.to_location&.bnafar_cnes if code == TRANSFER

      cnes
    end

    private_class_method :candidates, :compensate, :row, :destination
  end
end
