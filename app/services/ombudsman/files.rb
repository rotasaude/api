# Download do anexo da ouvidoria (ADR 0051; contrato §5; Q14): URL curta (5 min)
# amarrada à cidade, ao arquivo e ao usuário, com verifier e finalidade
# próprios (o token da ouvidoria não abre arquivo de exame nem do TFD, e
# vice-versa). O padrão de Tfd::Files. O nome gravado nunca sai: o download
# leva o nome gerado "anexo-<8 do id>.<ext>". Bytes e nome nunca vão a log,
# evento ou erro.
module Ombudsman
  module Files
    PURPOSE = Catalog::FILE_PURPOSE
    TOKEN_PURPOSE = "ombudsman_file".freeze
    TTL = Exams::Files::TTL
    EXTENSIONS = { "application/pdf" => "pdf", "image/jpeg" => "jpg", "image/png" => "png" }.freeze

    module_function

    # -> { url:, expires_at: } (recebe o id: ninguém precisa ler o arquivo cifrado para assinar)
    def link_for(file_id, user:, now: Time.current)
      expires_at = now + TTL
      token = verifier.generate({ "c" => Current.city.id, "f" => file_id, "u" => user.id, "x" => expires_at.to_i }, purpose: TOKEN_PURPOSE)
      { url: "/ombudsman/files/#{token}", expires_at: expires_at.utc.iso8601 }
    end

    def url_for(file_id, user:, now: Time.current) = link_for(file_id, user: user, now: now).fetch(:url)

    # ExamFile da ouvidoria, :expired ou nil (assinatura falsa, outra cidade,
    # outro usuário, arquivo que não é da ouvidoria).
    def resolve(token, user:, now: Time.current)
      payload = verifier.verified(token.to_s, purpose: TOKEN_PURPOSE)
      return nil unless payload.is_a?(Hash) && payload["c"] == Current.city.id && payload["u"] == user.id
      return :expired if now.to_i > payload["x"].to_i

      ExamFile.find_by(id: payload["f"], purpose: PURPOSE)
    end

    def filename(attachment, file) = "anexo-#{attachment.id[0, 8]}.#{EXTENSIONS.fetch(file.content_type)}"

    def verifier = Rails.application.message_verifier(TOKEN_PURPOSE)
    private_class_method :verifier
  end
end
