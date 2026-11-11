# Anexos da manifestação (ADR 0051; contrato §3/§5; Q2). O arquivo é do
# Exams::Files (PDF/JPEG/PNG pelos bytes mágicos, até 10 MB, cifrado com a
# chave da cidade, finalidade ombudsman_attachment). O dono fica na linha do
# anexo (sessão do cidadão ou usuário), sem coluna nova em exam_files e sem
# claim!. A linha nasce órfã no upload e o job de 24 h a apaga com o ExamFile
# órfão (cascata). O nome é cifrado e nunca é mostrado.
module Ombudsman
  module Attachments
    FILENAME_FORMAT = /\A[^\/\\\p{Cntrl}]+\z/

    module_function

    # -> Result.ok(attachment:) | fail(:invalid_request, details: { path: })
    #  | fail(:invalid_file). Exatamente um dono: citizen_session OU user.
    def upload(data:, content_type:, filename:, citizen_session: nil, user: nil)
      name = filename.is_a?(String) ? filename.strip : nil
      return invalid("filename") unless name && Catalog::FILENAME.cover?(name.length) && name.match?(FILENAME_FORMAT)
      return invalid("content_type") unless content_type.is_a?(String)
      return invalid("data") unless data.is_a?(String)

      ApplicationRecord.transaction do
        stored = Exams::Files.store_base64(data: data, content_type: content_type, user: user, purpose: Catalog::FILE_PURPOSE)
        if stored.failure?
          stored
        else
          Result.ok(attachment: OmbudsmanAttachment.create!(exam_file: stored.payload.fetch(:file), filename: name,
                                                            uploaded_by: citizen_session ? "citizen" : "staff",
                                                            citizen_session_id: citizen_session&.id, uploaded_by_user: user))
        end
      end
    end

    # Liga os anexos órfãos do dono à manifestação (e ao complemento, quando
    # há event) DENTRO da transação do comando. Cada id: uuid, único, do dono,
    # sem manifestação e com o ExamFile não consumido. O arquivo é consumido
    # na mesma transação (o job do órfão de 24 h não pode mais apagá-lo; o
    # trigger recusa ligar arquivo não consumido). Trava na ordem do job
    # (arquivo, depois anexo).
    # -> Result.ok(attachments:) | fail(:invalid_request, details: { path: "attachment_ids" })
    #  | fail(:too_many_attachments)
    def link!(ids:, manifestation:, owner:, event: nil)
      return Result.ok(attachments: []) if ids.nil? || ids == []
      return invalid("attachment_ids") unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(String) && id.match?(Ombudsman::BaseController::UUID) } && ids.uniq.size == ids.size
      return Result.fail(:too_many_attachments) if ids.size > Catalog::MAX_ATTACHMENTS

      file_ids = OmbudsmanAttachment.where(id: ids).pluck(:exam_file_id)
      free_files = ExamFile.lock("FOR UPDATE").where(id: file_ids, consumed_at: nil).order(:id).pluck(:id)
      rows = OmbudsmanAttachment.lock("FOR UPDATE").where(id: ids, ombudsman_manifestation_id: nil, exam_file_id: free_files).order(:id).to_a
      return invalid("attachment_ids") unless rows.size == ids.size && rows.all? { |row| owned_by?(row, owner) }

      ExamFile.where(id: rows.map(&:exam_file_id)).update_all(consumed_at: Time.current)
      OmbudsmanAttachment.where(id: ids).update_all(ombudsman_manifestation_id: manifestation.id, event_id: event&.id)
      Result.ok(attachments: OmbudsmanAttachment.where(id: ids).order(:created_at, :id).to_a)
    end

    def owned_by?(row, owner)
      owner.is_a?(User) ? row.uploaded_by_user_id == owner.id : row.citizen_session_id == owner.id
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path, problems: [ { error: "invalid_request", path: path } ] })
    private_class_method :owned_by?, :invalid
  end
end
