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
# um `delete` ou um `put` depois não vira `lost` por causa deles. Q31: perde-se
# só a parte não enviada, ou recusada e não reenviada até o fim de R+1; a
# parte em voo (`sending`, `processing`) segue com o DeliverJob até a BNAFAR
# responder, e a remessa dela não vira `lost` (o `late` avisa a demora). Quando
# ela acaba, a remessa segue a agregação normal, e uma rodada seguinte do
# `close!` a perde se sobrou parte não enviada ou recusada. Q30: `purge!` apaga
# todo payload 30 dias depois do envio.
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

    # Toda parte `post` ainda `queued` de remessa de `reference_on <= today - 2`
    # vira `failed` (não sai mais), também sob remessa já `lost` (a sobra de um
    # `sending` que voltou transitório) ou com outra parte em voo. Depois, a
    # remessa sem parte `post` em voo que não está `finished` ou tem registro
    # de parte `post` não aceito (recusado e não reenviado, ou que nunca saiu)
    # vira `lost`. -> [id] das que viraram `lost`
    def close!(today:, now: Time.current)
      sweep!(today, now)
      ids = BnafarSubmission.where(reference_on: ..(today - 2)).where.not(status: "lost")
                            .where.not(id: inflight_posts.select(:bnafar_submission_id))
                            .where("bnafar_submissions.status <> 'finished' OR EXISTS (#{unaccepted_posts.select('1').to_sql})")
                            .pluck(:id)
      ids.select { |id| lose!(id, now) }
    end

    # Q30: payload cifrado 30 dias depois do `sent_at`, em qualquer situação;
    # o registro nunca enviado, 30 dias depois do `created_at`. Os metadados
    # (situação, códigos, protocolo, evidência) ficam. -> quantos
    def purge!(now: Time.current)
      limit = now - Catalog::PAYLOAD_DAYS.days
      BnafarRecord.where.not(payload: nil)
                  .where("bnafar_records.sent_at < :limit OR (bnafar_records.sent_at IS NULL AND bnafar_records.created_at < :limit)", limit: limit)
                  .update_all(payload: nil, updated_at: now)
    end

    def inflight_posts = BnafarBatch.where(operation: "post", status: %w[sending processing])

    def unaccepted_posts
      BnafarRecord.joins(:bnafar_batch).where(status: %w[pending rejected], bnafar_batches: { operation: "post" })
                  .where("bnafar_records.bnafar_submission_id = bnafar_submissions.id")
    end

    def sweep!(today, now)
      BnafarBatch.where(operation: "post", status: "queued", bnafar_submission_id: BnafarSubmission.where(reference_on: ..(today - 2)).select(:id))
                 .update_all(status: "failed", last_error: WINDOW_CLOSED, finished_at: now, updated_at: now)
    end

    def lose!(id, now)
      BnafarSubmission.transaction(requires_new: true) do
        submission = BnafarSubmission.lock.find(id)
        next false if submission.status == "lost"

        # Recheca sob a trava: uma parte que entrou em voo agora segue (Q31).
        next false if inflight_posts.exists?(bnafar_submission_id: id)

        submission.update!(status: "lost")
        DomainEvents.publish("bnafar_submission.lost", bnafar_submission_id: submission.id)
        true
      end
    end
    private_class_method :inflight_posts, :unaccepted_posts, :sweep!, :lose!
  end
end
