# app/services/clinical_documents/qr.rb
# QR code do endereço de conferência (ADR 0033; spec §6), desenhado como
# vetor: um quadrado por módulo escuro, com a zona de silêncio de 4 módulos.
# Nível M de correção (15%): sobrevive a dobra e carimbo no papel.
require "rqrcode_core"

module ClinicalDocuments
  module Qr
    QUIET = 4

    module_function

    def matrix(text) = RQRCodeCore::QRCode.new(text, level: :m).modules

    def draw(pdf, text, at:, size:)
      modules = matrix(text)
      cell = size.to_f / (modules.size + (2 * QUIET))
      x0, y0 = at
      pdf.fill_color "000000"
      modules.each_with_index do |row, r|
        row.each_with_index do |dark, c|
          pdf.fill_rectangle([ x0 + ((c + QUIET) * cell), y0 - ((r + QUIET) * cell) ], cell, cell) if dark
        end
      end
    end
  end
end
