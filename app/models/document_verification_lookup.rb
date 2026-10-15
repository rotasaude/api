# app/models/document_verification_lookup.rb
# Trilha da página pública (ADR 0033; spec §6): só o documento achado (ou
# nenhum), a via e o resultado — nunca IP, código digitado ou ano.
class DocumentVerificationLookup < ApplicationRecord
  belongs_to :clinical_document, optional: true
  belongs_to :lab_report, optional: true
end
