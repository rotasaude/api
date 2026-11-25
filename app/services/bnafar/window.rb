# As janelas do envio ao SI-BNAFAR (módulo 27b; Valor 6; Q14, Q25; R10, R12,
# R19): uma régua só, usada pelo Build (DELETE × estorno fora da janela), pela
# Delivery (até quando tentar) e, na Task 12, pelo RetrySubmission, pelo
# CorrectExit e pelo Json.
#
#   - reenvio da remessa de R: até o fim de R+1 no fuso corrente (o da cidade
#     dentro de CityConnection.with); às 00:00 de R+2 ela vira `lost`;
#   - correção (PUT) e exclusão (DELETE) de um registro: até CORRECTION_DAYS
#     dias do `sent_at` do registro (Q25: do envio, não do aceite; o fake conta
#     igual).
#
# `close!` e `purge!` são a limpeza do DailyJob, que roda com o `bnafar`
# desligado (R19). `close!` olha só as partes `post` (R10): a remessa velha com
# um `delete` ou um `put` depois não vira `lost` por causa deles.
module Bnafar
  module Window
    WINDOW_CLOSED = "window_closed".freeze

    module_function

    # Time | nil (registro nunca enviado não tem janela). O registro de correção
    # (`replaces_record_id`, PUT) herda a janela do registro ORIGINAL, o primeiro
    # da cadeia: o prazo da BNAFAR conta do primeiro envio, e corrigir de novo
    # não o estende (Q25).
    def correctable_until(record)
      record = record.replaces_record while record.replaces_record_id && record.replaces_record
      record.sent_at && (record.sent_at + Catalog::CORRECTION_DAYS.days)
    end

    def correctable?(record, now: Time.current)
      limit = correctable_until(record)
      !limit.nil? && now <= limit
    end

    def retry_until(submission) = (submission.reference_on + 1).in_time_zone.end_of_day

    def retryable?(submission, now: Time.current) = now <= retry_until(submission)

    # Remessa de `reference_on <= today - 2` ainda não `finished`, ou `finished`
    # com registro recusado numa parte `post`, vira `lost` (e as partes `post`
    # ainda `queued` viram `failed`, que não saem mais). -> [id]
    def close!(today:, now: Time.current)
      rejected = BnafarRecord.joins(:bnafar_batch)
                             .where(status: "rejected", bnafar_batches: { operation: "post" })
                             .where("bnafar_records.bnafar_submission_id = bnafar_submissions.id")
      ids = BnafarSubmission.where(reference_on: ..(today - 2)).where.not(status: "lost")
                            .where("bnafar_submissions.status <> 'finished' OR EXISTS (#{rejected.select('1').to_sql})")
                            .pluck(:id)
      ids.select { |id| lose!(id, now) }
    end

    # Payload cifrado de registro aceito há mais de PAYLOAD_DAYS dias vira NULL. -> quantos
    def purge!(now: Time.current)
      BnafarRecord.where(status: "accepted").where(accepted_at: ...(now - Catalog::PAYLOAD_DAYS.days))
                  .where.not(payload: nil).update_all(payload: nil, updated_at: now)
    end

    def lose!(id, now)
      BnafarSubmission.transaction(requires_new: true) do
        submission = BnafarSubmission.lock.find(id)
        next false if submission.status == "lost"

        submission.batches.where(operation: "post", status: "queued")
                  .update_all(status: "failed", last_error: WINDOW_CLOSED, finished_at: now, updated_at: now)
        submission.update!(status: "lost")
        DomainEvents.publish("bnafar_submission.lost", bnafar_submission_id: submission.id)
        true
      end
    end
    private_class_method :lose!
  end
end
