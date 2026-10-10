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
    def display(code) = "#{code[0, 5]}-#{code[5, 5]}"

    def normalize(input)
      code = input.to_s.upcase.gsub(/[\s-]/, "")
      code.size == LENGTH && code.chars.all? { |char| ALPHABET.include?(char) } ? code : nil
    end
  end
end
