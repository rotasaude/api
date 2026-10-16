# app/services/clinical_documents/codes.rb
# Códigos de conferência (ADR 0033; Valores fixados 2): token de 128 bits para
# a URL do QR code e código curto de 10 caracteres sem ambíguos (0, 1, I, L,
# O) para digitar; a entrada aceita minúsculas, espaços e hífen.
module ClinicalDocuments
  module Codes
    ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ".chars.freeze
    LENGTH = 10

    module_function

    def token = SecureRandom.urlsafe_base64(16)
    def short_code = Array.new(LENGTH) { ALPHABET[SecureRandom.random_number(ALPHABET.size)] }.join
    # B58: o código curto da conferência pública (/v) é único entre documentos
    # clínicos e laudos (o desempate pelo ano no /v fica como defesa).
    def public_short_code
      loop do
        code = short_code
        return code unless ClinicalDocument.exists?(short_code: code) || LabReport.exists?(short_code: code)
      end
    end

    def display(code) = "#{code[0, 5]}-#{code[5, 5]}"

    def normalize(input)
      code = input.to_s.upcase.gsub(/[\s-]/, "")
      code.size == LENGTH && code.chars.all? { |char| ALPHABET.include?(char) } ? code : nil
    end
  end
end
