# Correção de uma saída externa já aceita pela BNAFAR (módulo 27b; contrato §3,
# §4; Q8, Q25; R12): `POST /pharmacy/bnafar/records/:id/correct`. A correção vale
# para a SAÍDA INTEIRA: atualiza a saída externa (tipo, destino e motivo, com
# `version + 1`) e gera, para cada registro vigente dela (aceito, com código, não
# excluído e ainda não substituído), um registro novo com `replaces_record_id` e
# o `codigo` do original, num lote `put` por remessa. O saldo não muda: a
# saída (movimento) é a mesma.
#
# `attrs` (chaves String): `exit_type?`, `destination_kind?`, `destination_code?`
# e `reason` (obrigatório, 10..500); o que falta vem da saída atual, e a conta é
# a do Pharmacy::RecordExternalExit.header. Nada igual ao que já está → `invalid_request`.
# `expected_version` é a `version` da saída: diferente sob a trava →
# `external_exit_changed`.
#
# `not_correctable`: o registro não é uma saída externa aceita e com código, ou
# já foi substituído, ou há uma correção ainda em voo (`pending`).
# `correction_window_closed`: passados 30 dias (Window, do `sent_at` do registro
# ORIGINAL da cadeia) do registro mais antigo da saída (R12: nenhuma conta de
# data aqui). Evento `bnafar_record.corrected` por registro novo, só ids
# (bnafar_record_id, replaces_record_id, user_id).
module Bnafar
  module CorrectExit
    KEYS = %w[exit_type destination_kind destination_code reason].freeze
    PATH_MAX = 64

    module_function

    # -> Result.ok(records:, batches:) |
    #    fail(:not_correctable | :correction_window_closed | :external_exit_changed | :invalid_request | :invalid_cnpj |
    #         :expected_version_required, details: { path: })
    def call(record:, attrs:, expected_version:, by:, now: Time.current)
      return refuse("attrs", :invalid_request) unless attrs.is_a?(Hash)

      attrs = attrs.transform_keys(&:to_s)
      unknown = (attrs.keys - KEYS).first
      return refuse(unknown.to_s[0, PATH_MAX], :invalid_request) if unknown
      return refuse("expected_version", :expected_version_required) unless expected_version.is_a?(Integer)
      return Result.fail(:not_correctable) unless external_exit?(record)

      StockExternalExit.transaction(requires_new: true) do
        external = StockExternalExit.lock.find(record.stock_external_exit_id)
        next Result.fail(:external_exit_changed) if external.version != expected_version

        tips = current_records(external)
        next Result.fail(:not_correctable) if tips.none? { |row| row.id == record.id } || correction_in_flight?(external)

        limit = tips.filter_map { |row| Window.correctable_until(row) }.min
        next Result.fail(:correction_window_closed) if limit.nil? || now > limit

        header = header_for(external, attrs)
        next header if header.is_a?(Result)

        apply!(external, header, tips, by)
      end
    end

    def external_exit?(record)
      record.subject == "exit" && record.stock_external_exit_id.present? && record.status == "accepted" &&
        record.deleted_at.nil? && record.bnafar_code.present?
    end

    # Os registros vigentes da saída: aceitos, com código, não excluídos e sem
    # substituto `pending` ou `accepted` (o substituto recusado deixa o original vigente).
    def current_records(external)
      replaced = BnafarRecord.where(stock_external_exit_id: external.id, status: %w[pending accepted])
                             .where.not(replaces_record_id: nil).select(:replaces_record_id)
      BnafarRecord.where(stock_external_exit_id: external.id, subject: "exit", status: "accepted", deleted_at: nil)
                  .where.not(bnafar_code: nil).where.not(id: replaced).order(:created_at, :id).lock.to_a
    end

    def correction_in_flight?(external)
      BnafarRecord.where(stock_external_exit_id: external.id, status: "pending").where.not(replaces_record_id: nil).exists?
    end

    # -> { exit_type:, destination_kind:, destination_code:, reason: } | Result.fail
    def header_for(external, attrs)
      return refuse("reason", :invalid_request) unless attrs.key?("reason")

      merged = { "exit_type" => external.exit_type, "destination_kind" => external.destination_kind,
                 "destination_code" => external.destination_code }.merge(attrs)
      problems, header = Pharmacy::RecordExternalExit.header(merged)
      return refuse(problems.first[:path], problems.first[:error]) if problems.any?

      current = { exit_type: external.exit_type, destination_kind: external.destination_kind, destination_code: external.destination_code,
                  reason: external.reason }
      header == current ? refuse("attrs", :invalid_request) : header
    end

    def apply!(external, header, tips, by)
      quantities = {}
      movements = tips.to_h do |tip|
        link = BnafarMovementLink.find_by(bnafar_record_id: root_of(tip).id, kind: "exit")
        return Result.fail(:not_correctable) unless link

        quantities[link.stock_movement_id] = tip.payload && JSON.parse(tip.payload).dig("itens", 0, "quantidade")
        [ tip.id, link.stock_movement_id ]
      end
      # Antes de gravar: toda saída precisa continuar sendo uma saída (a nada se grava pela metade).
      return Result.fail(:not_correctable) unless Exits.reload(movements: movements.values, quantities: quantities.compact).size == movements.size

      version = external.version + 1
      external.update!(header.merge(version: version))
      rows = Exits.reload(movements: movements.values, quantities: quantities.compact).index_by { |row| row.movement.id }

      batches = {}
      news = tips.map do |tip|
        batch = (batches[tip.bnafar_submission_id] ||= BnafarBatch.create!(bnafar_submission_id: tip.bnafar_submission_id, operation: "put",
                                                                            status: "queued", next_attempt_at: Time.current))
        code = Digest::UUID.uuid_v5(Build::NAMESPACE, [ tip.id, "put", version ].join(":"))
        payload = Payload.exit(rows.fetch(movements.fetch(tip.id)), origin_code: code).merge("codigo" => tip.bnafar_code)
        BnafarRecord.create!(bnafar_submission_id: tip.bnafar_submission_id, bnafar_batch: batch, origin_code: code, subject: "exit",
                             stock_location_id: tip.stock_location_id, item_key: tip.item_key, stock_external_exit_id: external.id,
                             replaces_record_id: tip.id, payload: JSON.generate(payload))
      end
      news.each do |row|
        DomainEvents.publish("bnafar_record.corrected", bnafar_record_id: row.id, replaces_record_id: row.replaces_record_id, user_id: by.id)
      end
      Result.ok(records: news, batches: batches.values)
    end

    def root_of(record)
      record = record.replaces_record while record.replaces_record_id
      record
    end

    def refuse(path, error) = Result.fail(error, details: { path: path })

    private_class_method :external_exit?, :current_records, :correction_in_flight?, :header_for, :apply!, :root_of, :refuse
  end
end
