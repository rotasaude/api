# Linha do tempo do paciente (ADR 0035). Namespace explícito: o Zeitwerk carrega
# este arquivo ao primeiro uso de Timeline::*, então KINDS existe sem depender
# de Timeline::Entry já ter sido carregado.
#
# Módulo 32a: `urgency` (a visita à UPA) entra para o profissional, o cidadão
# e a página do PEC externo — esta na forma profissional, sem o registro por
# engano nem o provisório (contrato §14 Q27; Timeline::Query::PEC_FILTERED_KINDS).
# Segue fora do LEDI: a UPA não é atenção básica.
#
# Módulo 31: os kinds do CAPS (`psychosocial`, `psychosocial_link`) NÃO entram
# aqui — ver Timeline::Query::{CAPS_ONLY_KINDS,LINK_KINDS} (contrato §10, P18).
module Timeline
  KINDS = %w[triage attendance screening appointment consultation clinical_document controlled_notification campaign exam procedure dispensation vaccination transport urgency].freeze
end
