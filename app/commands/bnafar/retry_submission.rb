# Reenvio dos registros recusados de uma remessa (módulo 27b; contrato §3;
# Q25; R10, R11, R12; Review Focus 3): só no dia seguinte ao de referência (R+1,
# no fuso da cidade; Window.retry_until). A correção é feita no dado de origem
# (complemento do lote, CNES do local, código do produto) e aqui o registro se
# remonta pelo Build (Build.rebuild: o dado de HOJE sobre a fotografia de R, o
# MESMO `origin_code`), num lote `post` NOVO:
#
#   - o registro `rejected` vira `pending` trocando juntos o payload, o lote e
#     os códigos de erro (R11); `sent_at` não se mexe (a âncora da janela de
#     30 dias é o primeiro envio, Q25);
#   - a remessa fechada (`finished` | `failed`) volta a `queued` só com o lote
#     novo já `queued` (R10); a que ainda anda fica como está;
#   - só os registros de `post` e sem pendência de dado entram; o recusado cujo
#     dado ainda tem pendência continua `rejected` (e, sem nenhum que entre, a
#     resposta é `nothing_to_retry`).
#
# A janela é a da Bnafar::Window: `today > R + 1` ou remessa `lost` →
# `retry_window_closed`. `domains` chega lido (Gate.domains_through de R) fora
# da transação da cidade. Evento `bnafar_submission.queued` só com o id.
module Bnafar
  module RetrySubmission
    module_function

    # -> Result.ok(batch:, batches:, records:) | fail(:retry_window_closed | :nothing_to_retry)
    def call(submission:, by:, today:, domains:)
      BnafarSubmission.transaction(requires_new: true) do
        locked = BnafarSubmission.lock.find(submission.id)
        next Result.fail(:retry_window_closed) unless open?(locked, today)

        rejected = locked.records.joins(:bnafar_batch)
                         .where(status: "rejected", replaces_record_id: nil, bnafar_batches: { operation: "post" })
                         .order(:id).lock("FOR UPDATE OF bnafar_records").to_a
        payloads = rejected.empty? ? {} : Build.rebuild(locked, rejected, domains: domains)
        ready = rejected.select { |record| payloads.key?(record.origin_code) }
        next Result.fail(:nothing_to_retry) if ready.empty?

        requeue!(locked, ready, payloads)
      end
    end

    def open?(submission, today)
      submission.status != "lost" && Window.retryable?(submission, now: [ Time.current, today.in_time_zone ].max)
    end

    def requeue!(submission, records, payloads)
      now = Time.current
      batches = records.each_slice(Limits::RECORDS_PER_BATCH).map do |slice|
        batch = BnafarBatch.create!(bnafar_submission: submission, operation: "post", status: "queued", next_attempt_at: now)
        slice.each do |record|
          record.update!(status: "pending", payload: JSON.generate(payloads.fetch(record.origin_code)), bnafar_batch_id: batch.id,
                         error_codes: [], rejected_items: 0)
        end
        batch
      end
      submission.update!(status: "queued") if %w[finished failed].include?(submission.status)
      DomainEvents.publish("bnafar_submission.queued", bnafar_submission_id: submission.id)
      Result.ok(batch: batches.first, batches: batches, records: records)
    end

    private_class_method :open?, :requeue!
  end
end
