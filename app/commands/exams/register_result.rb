# Registra o resultado (ADR 0036; spec §5 etapa 5, §6; contrato A17): uma vez
# por pedido (checado sob a trava do pedido; índice único como última
# palavra), só de agendado/coletado (a transição relê o status sob a mesma
# trava), com o PDF; crítico e/ou solicitante sem vínculo escalam na mesma
# transação, um escalonamento por motivo (A31). Mesma porta para unidade,
# portal e FHIR (Task 14). Savepoint próprio: a recusa depois de consumir o
# PDF desfaz o consumo (o arquivo volta a ser órfão; o job o apaga em 24 h)
# mesmo dentro da transação de quem chama. Valor, crítico e PDF nunca vão a
# log, evento (além do `critical` do contrato §12) ou mensagem de erro.
module Exams
  module RegisterResult
    module_function

    def call(order:, source:, released_on:, laboratory_name:, critical:, values:, file: nil, file_id: nil, by_user: nil,
             by_provider: nil, fhir_identifier: nil, now: Time.current)
      released = parse_date(released_on)
      return Result.fail(:invalid_released_on) unless released && released <= now.in_time_zone.to_date
      return Result.fail(:invalid_laboratory) unless laboratory_name.is_a?(String) && laboratory_name.strip.length.between?(1, 160)
      return Result.fail(:invalid_critical) unless [ true, false ].include?(critical)

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        order.lock!
        next result = Result.fail(:result_already_registered) if ExamResult.exists?(exam_order_id: order.id)

        checked = if values.is_a?(Result) then values
                  elsif source == "fhir" then Result.ok(values: values)
                  else ResultValues.from_input(order.catalog_item, values)
                  end
        next result = checked if checked.failure?

        file ||= Files.claim!(file_id: file_id, user: by_user, provider: by_provider)
        unless file&.content_type == "application/pdf"
          result = Result.fail(:missing_pdf)
          raise ActiveRecord::Rollback # desfaz o consumo do arquivo que não é PDF
        end

        file.update!(consumed_at: now) unless file.consumed?
        moved = Transition.call(order: order, kind: "resulted", actor_user: by_user, actor_provider: by_provider,
                                event_payload: { source: source, critical: critical }, now: now)
        if moved.failure?
          result = moved
          raise ActiveRecord::Rollback
        end
        stored = ExamResult.create!(exam_order: order, patient: order.patient, sigtap_code: order.sigtap_code, origin: "order",
                                    source: source, pdf_file: file, values: checked.payload[:values].to_json, released_on: released,
                                    laboratory_name: laboratory_name.strip, critical: critical, fhir_identifier: fhir_identifier,
                                    exam_provider_id: by_provider&.id || order.exam_provider_id, registered_by_user: by_user,
                                    registered_by_provider: by_provider)
        escalation_reasons(order, critical).each { |reason| Escalate.call(order: order, reason: reason, now: now) }
        result = Result.ok(result: stored)
      end
      result
    end

    # A31: crítico e solicitante digitado são motivos distintos; os dois valem.
    def escalation_reasons(order, critical)
      [ ("critical" if critical), ("unlinked_requester" if order.requester_user_id.nil?) ].compact
    end

    def parse_date(raw)
      raw.is_a?(Date) ? raw : (raw.is_a?(String) && raw.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Date.iso8601(raw) : nil)
    rescue Date::Error
      nil
    end
    private_class_method :parse_date, :escalation_reasons
  end
end
