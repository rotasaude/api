# Comprovante da prestação de contas do TFD (ADR 0048; §14 T13): o arquivo é
# do Exams::Files (21a: PDF/JPEG/PNG pelos bytes mágicos, até 10 MB, cifrado
# com a chave da cidade, finalidade tfd_accountability). Download por URL
# curta (5 min) amarrada à cidade, ao arquivo e ao usuário, com verifier e
# finalidade próprios: o token do TFD não abre arquivo de exame e vice-versa.
# Nome do arquivo e bytes nunca vão a log, evento ou erro.
module Tfd
  module Files
    PURPOSE = Catalog::FILE_PURPOSE
    TOKEN_PURPOSE = "tfd_file".freeze
    TTL = Exams::Files::TTL
    EXTENSIONS = { "application/pdf" => "pdf", "image/jpeg" => "jpg", "image/png" => "png" }.freeze

    module_function

    # Base64 estrito → bytes conferidos (tipo, bytes mágicos, 1 byte..10 MB); senão nil.
    def decode(data, content_type)
      return nil unless data.is_a?(String) && content_type.is_a?(String) && data.length <= (Exams::Files::MAX_BYTES * 4 / 3) + 8

      bytes = Base64.strict_decode64(data)
      magic = Exams::Files::MAGIC[content_type]
      magic && bytes.bytesize.between?(1, Exams::Files::MAX_BYTES) && bytes.b.start_with?(magic) ? bytes : nil
    rescue ArgumentError
      nil
    end

    # -> Result.ok(file:) | fail(:invalid_file). O `consumed_at` é gravado aqui:
    # o arquivo nasce ligado à prestação de contas (o job do órfão de 24 h não o apaga).
    def store(bytes:, content_type:, user:)
      stored = Exams::Files.store(bytes: bytes, content_type: content_type, user: user, purpose: PURPOSE)
      return stored if stored.failure?

      file = stored.payload.fetch(:file)
      file.update!(consumed_at: Time.current)
      Result.ok(file: file)
    end

    # Nome gerado quando o corpo não traz um.
    def generated_name(file, on: Date.current) = "comprovante-#{on.iso8601}.#{EXTENSIONS.fetch(file.content_type)}"

    def url_for(file, user:, now: Time.current)
      token = verifier.generate({ "c" => Current.city.id, "f" => file.id, "u" => user.id, "x" => (now + TTL).to_i }, purpose: TOKEN_PURPOSE)
      "/tfd/files/#{token}"
    end

    # ExamFile da prestação de contas, :expired ou nil (assinatura falsa, outra
    # cidade, outro usuário, arquivo que não é do TFD).
    def resolve(token, user:, now: Time.current)
      payload = verifier.verified(token.to_s, purpose: TOKEN_PURPOSE)
      return nil unless payload.is_a?(Hash) && payload["c"] == Current.city.id && payload["u"] == user.id
      return :expired if now.to_i > payload["x"].to_i

      ExamFile.find_by(id: payload["f"], purpose: PURPOSE)
    end

    def verifier = Rails.application.message_verifier(TOKEN_PURPOSE)
    private_class_method :verifier
  end
end
