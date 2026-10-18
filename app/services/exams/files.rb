# Arquivos do exame (ADR 0036; Desvio 5; Divergências D3/D4): guia (PDF,
# JPEG, PNG) e laudo (PDF), conferidos pelos bytes mágicos, até 10 MB,
# cifrados com a chave da cidade. Download por URL curta (5 min) amarrada à
# cidade, ao arquivo e ao usuário; a trilha é de quem chama.
module Exams
  module Files
    MAX_BYTES = 10 * 1024 * 1024
    MAGIC = { "application/pdf" => "%PDF-".b, "image/jpeg" => "\xFF\xD8\xFF".b, "image/png" => "\x89PNG\r\n\x1A\n".b }.freeze
    PURPOSE = "exam_file".freeze
    TTL = 5.minutes

    module_function

    def store(bytes:, content_type:, user: nil, provider: nil, purpose: nil)
      bytes = bytes.to_s.b
      magic = MAGIC[content_type]
      return Result.fail(:invalid_file) unless magic && bytes.bytesize.between?(1, MAX_BYTES) && bytes.start_with?(magic)

      file = ExamFile.create!(content_type: content_type, byte_size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes),
                              data: Base64.strict_encode64(bytes), uploaded_by_user: user, exam_provider: provider, purpose: purpose)
      Result.ok(file: file)
    end

    def store_base64(data:, content_type:, user: nil, provider: nil, purpose: nil)
      return Result.fail(:invalid_file) unless data.is_a?(String) && data.length <= (MAX_BYTES * 4 / 3) + 8

      store(bytes: Base64.strict_decode64(data), content_type: content_type, user: user, provider: provider, purpose: purpose)
    rescue ArgumentError
      Result.fail(:invalid_file)
    end

    # Liga o arquivo a um pedido/resultado: só o não consumido do mesmo autor e da
    # mesma finalidade (nil = 21a; o upload do CEQ só serve ao relatório anual).
    def claim!(file_id:, user: nil, provider: nil, purpose: nil)
      return nil unless file_id.is_a?(String) && file_id.match?(Exams::BaseController::UUID)

      file = ExamFile.lock.find_by(id: file_id, consumed_at: nil, purpose: purpose)
      return nil unless file
      return nil unless (user && file.uploaded_by_user_id == user.id) || (provider && file.exam_provider_id == provider.id)

      file.update!(consumed_at: Time.current)
      file
    end

    # O vencimento vai no próprio payload assinado (não no expires_in do
    # verifier, que devolve nil igual para vencido e para falso): o vencido
    # responde 410 link_expired (dashboard D11) e o dashboard relê o exame.
    def url_for(file, user:, now: Time.current)
      token = verifier.generate({ "c" => Current.city.id, "f" => file.id, "u" => user.id, "x" => (now + TTL).to_i }, purpose: PURPOSE)
      "/exams/files/#{token}"
    end

    # ExamFile, :expired ou nil (assinatura falsa, outra cidade, outro usuário).
    def resolve(token, user:, now: Time.current)
      payload = verifier.verified(token.to_s, purpose: PURPOSE)
      return nil unless payload.is_a?(Hash) && payload["c"] == Current.city.id && payload["u"] == user.id
      return :expired if now.to_i > payload["x"].to_i

      ExamFile.find_by(id: payload["f"])
    end

    def filename(file) = "exame-#{file.id[0, 8]}.#{{ "application/pdf" => "pdf", "image/jpeg" => "jpg", "image/png" => "png" }.fetch(file.content_type)}"

    def verifier = Rails.application.message_verifier(PURPOSE)
    private_class_method :verifier
  end
end
