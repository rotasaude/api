# Linha do tempo do paciente (ADR 0035). Namespace explícito: o Zeitwerk carrega
# este arquivo ao primeiro uso de Timeline::*, então KINDS existe sem depender
# de Timeline::Entry já ter sido carregado.
module Timeline
  KINDS = %w[triage attendance screening appointment consultation clinical_document controlled_notification campaign exam].freeze
end
