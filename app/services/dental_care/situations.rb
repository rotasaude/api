# Situações do odontograma do PEC (ADR 0046; Desvio 4; contrato §16 O3):
# coroa, raiz e arcada, as que valem na face e as restrições por dente, lidas
# de config/dental/situations.yml (carregado uma vez por processo). Sem dado
# pessoal.
module DentalCare
  module Situations
    PATH = Rails.root.join("config/dental/situations.yml")
    PARTS = %w[crown root arch].freeze
    TEETH = (Catalog::PERMANENT_TEETH + Catalog::DECIDUOUS_TEETH).freeze

    module_function

    def rows = (@rows ||= YAML.load_file(PATH).fetch("situations").map(&:freeze).freeze)

    # `part` crown, root, arch ou face (as de coroa que valem numa face).
    def list(part)
      chosen = part.to_s == "face" ? rows.select { |row| row["part"] == "crown" && row["face"] } : rows.select { |row| row["part"] == part.to_s }
      chosen.map { |row| { code: row["code"], label: row["label"], abbr: row["abbr"] } }
    end

    def find(code, part) = rows.find { |row| row["part"] == part.to_s && row["code"] == code.to_s }
    def face_situation?(code) = !!find(code, "crown")&.fetch("face")

    def valid?(code, part:, tooth:, face: nil) = reason(code, part: part, tooth: tooth, face: face).nil?

    # :invalid_situation (código, parte ou face que não existem, ou situação
    # que não vale na face) | :situation_not_allowed_for_tooth (dente
    # inexistente, decíduo que não recebe a situação ou fora da lista dela).
    # Na arcada o dente é opcional.
    def reason(code, part:, tooth:, face: nil)
      row = code.is_a?(String) && PARTS.include?(part.to_s) ? find(code, part) : nil
      return :invalid_situation unless row
      return :invalid_situation if face && !(row["face"] && Catalog::FACES.include?(face))
      return nil if tooth.nil? && part.to_s == "arch"

      allowed_for_tooth?(row, tooth) ? nil : :situation_not_allowed_for_tooth
    end

    def allowed_for_tooth?(row, tooth)
      return false unless TEETH.include?(tooth)
      return false if Catalog::DECIDUOUS_TEETH.include?(tooth) && !row["deciduous"]

      row["teeth"].nil? || row["teeth"].include?(tooth)
    end
    private_class_method :allowed_for_tooth?
  end
end
