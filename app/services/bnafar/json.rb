# Formas JSON do envio à BNAFAR para o dashboard (módulo 27b; contrato §3, §6;
# Q16, Q25; R12). Nunca o payload (nem o corpo, a evidência ou o texto da
# BNAFAR: só os códigos MSG) e nenhum dado de pessoa. Os prazos vêm da
# Bnafar::Window: nenhuma conta de data aqui.
#
# Registro (`record`):
#   { id, subject, status, lost, lost_reason, deleted, stock_location_id,
#     location_name, item_key, item_label, error_codes, rejected_items,
#     bnafar_code, protocol, retry_until, correct_until, stock_external_exit_id,
#     stock_external_exit_version }
#   - `lost`: o registro NÃO aceito de uma remessa `lost` (nunca chegou, ou
#     chegou recusado e a janela fechou);
#   - `lost_reason`: o primeiro código MSG que não é a MSG47 ("todos os itens
#     inconsistentes", só um resumo das outras); se só houver a MSG47, ela;
#     sem código nenhum (nunca foi enviado) `"not_sent"`; nil se não está perdido;
#   - `protocol`: o do lote do registro (o `post`, ou o `put` da correção);
#   - `retry_until`: só no recusado (de `post`) de remessa ainda não perdida;
#   - `correct_until`: só na saída externa aceita, não excluída e não substituída
#     por uma correção não recusada (Window, do `sent_at` do registro original).
module Bnafar
  module Json
    NOT_SENT = "not_sent".freeze
    ALL_INCONSISTENT = "MSG47".freeze
    RECORD_PRELOAD = %i[bnafar_batch bnafar_submission stock_location replaces_record stock_external_exit].freeze

    module_function

    # `label_index`: Json.labels(records) quando se serializam várias (uma consulta por tipo de item).
    # `replaced`: Json.replaced_ids(records) quando se serializam várias (uma consulta só).
    def record(record, label_index: nil, replaced: nil)
      submission = record.bnafar_submission
      lost = submission.status == "lost" && record.status != "accepted"
      { id: record.id, subject: record.subject, status: record.status, lost: lost, lost_reason: lost ? lost_reason(record) : nil,
        deleted: record.deleted_at.present?, stock_location_id: record.stock_location_id, location_name: record.stock_location.name,
        item_key: record.item_key, item_label: (label_index || labels([ record ]))[record.item_key], error_codes: record.error_codes,
        rejected_items: record.rejected_items, bnafar_code: record.bnafar_code, protocol: record.bnafar_batch&.protocol,
        retry_until: retry_until(record, submission), correct_until: correct_until(record, replaced || replaced_ids([ record ])),
        stock_external_exit_id: record.stock_external_exit_id, stock_external_exit_version: record.stock_external_exit&.version }
    end

    def lost_reason(record)
      codes = record.error_codes
      codes.find { |code| code != ALL_INCONSISTENT } || codes.first || NOT_SENT
    end

    # { item_key => rótulo } dos registros, sem pessoa.
    def labels(records)
      keys = records.map(&:item_key).uniq.group_by { |key| key.split(":", 2).first }
      ids = ->(domain) { Array(keys[domain]).map { |key| key.split(":", 2).last } }
      catalog = MedicationCatalogItem.where(id: ids.call(Stock::Domain::MEDICATION)).index_by { |item| item.id.to_s }
      vector = VectorProduct.where(id: ids.call(Stock::Domain::VECTOR_CONTROL)).index_by { |item| item.id.to_s }
      records.map(&:item_key).uniq.to_h do |key|
        domain, id = key.split(":", 2)
        label = case domain
                when Stock::Domain::IMMUNOBIOLOGICAL then Vaccination::Immunobiologicals.find(id)&.name || id
                when Stock::Domain::VECTOR_CONTROL then vector[id]&.name || id
                else catalog[id]&.label || id
                end
        [ key, label ]
      end
    end

    # A remessa: `counts` por situação do registro (accepted, rejected, pending,
    # lost); a que se perdeu soma os não aceitos em `lost` (e zera os outros dois).
    def submission(submission, tally: nil)
      { id: submission.id, reference_on: submission.reference_on, subject: submission.subject, environment: submission.environment,
        status: submission.status, attempts: submission.attempts, last_error: submission.last_error, sent_at: submission.sent_at,
        finished_at: submission.finished_at, retry_until: Window.retry_until(submission),
        counts: tally || counts(submission.id => submission)[submission.id] }
    end

    # { submission_id => { accepted:, rejected:, pending:, lost: } } numa consulta só.
    def counts(submissions)
      grouped = BnafarRecord.where(bnafar_submission_id: submissions.keys, replaces_record_id: nil)
                            .group(:bnafar_submission_id, :status).count
      submissions.to_h do |id, submission|
        row = %w[accepted rejected pending].to_h { |status| [ status.to_sym, grouped.fetch([ id, status ], 0) ] }
        row = { accepted: row[:accepted], rejected: 0, pending: 0, lost: row[:rejected] + row[:pending] } if submission.status == "lost"
        row[:lost] ||= 0
        [ id, row ]
      end
    end

    # Os dias da faixa de situação: por dia de referência, uma linha por assunto.
    def days(submissions)
      counts = counts(submissions.index_by(&:id))
      submissions.group_by(&:reference_on).sort.reverse.map do |day, rows|
        { reference_on: day,
          subjects: rows.sort_by(&:subject).map { |row| { subject: row.subject, status: row.status }.merge(counts.fetch(row.id)) } }
      end
    end

    def retry_until(record, submission)
      return nil unless record.status == "rejected" && submission.status != "lost" && record.replaces_record_id.nil?

      Window.retry_until(submission)
    end

    # Ids dos registros (dentre `records`) já substituídos por outro (`replaces_record_id`).
    # Correção recusada não substitui: o original aceito segue como a versão vigente na BNAFAR.
    def replaced_ids(records)
      BnafarRecord.where(replaces_record_id: records.map(&:id)).where.not(status: "rejected").pluck(:replaces_record_id).to_set
    end

    # Só o registro vigente (o que ninguém substituiu) mantém o prazo de correção.
    def correct_until(record, replaced)
      return nil unless record.stock_external_exit_id && record.status == "accepted" && record.deleted_at.nil?
      return nil if replaced.include?(record.id)

      Window.correctable_until(record)
    end

    private_class_method :lost_reason, :retry_until, :correct_until
  end
end
