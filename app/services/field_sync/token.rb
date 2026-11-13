# Token do aparelho de campo (módulo 24b, ADR 0052; contrato §9.1): 32 bytes
# aleatórios em base64url, com o prefixo rsf_. Só sai na resposta do cadastro;
# o banco guarda o SHA-256 (FieldDevice.digest). O QR leva o host da cidade e o
# token: "rotasaude-field:v1:" + base64url(JSON { host, token }).
module FieldSync
  module Token
    module_function

    def generate = Catalog::TOKEN_PREFIX + Base64.urlsafe_encode64(SecureRandom.bytes(Catalog::TOKEN_BYTES), padding: false)

    def qr_payload(host:, token:) = Catalog::QR_PREFIX + Base64.urlsafe_encode64(JSON.generate(host: host, token: token), padding: false)
  end
end
