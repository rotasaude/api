# Catálogo da ouvidoria (ADR 0051): tipos, modos, estados, prazos de texto e
# eventos. Valores fixados pelo plano do módulo 33; nada aqui é dado pessoal.
module Ombudsman
  module Catalog
    KINDS = %w[complaint report praise suggestion request].freeze
    MODES = %w[identified preserved anonymous].freeze
    CHANNELS = %w[web in_person phone ouvidorsus].freeze
    STAFF_CHANNELS = %w[in_person phone ouvidorsus].freeze
    STATES = %w[received in_analysis forwarded awaiting_complement answered archived].freeze
    FINAL_STATES = %w[answered archived].freeze
    OPEN_STATES = (STATES - FINAL_STATES).freeze
    RESOLUTIONS = %w[resolved not_resolved].freeze
    RESOLUTION_KINDS = %w[complaint request report].freeze
    ARCHIVE_REASONS = %w[duplicate no_complement lack_of_clarity lack_of_civility improper loss_of_object forwarded_elsewhere].freeze
    # Q4 (preflight F-15): o texto do arquivamento chega pronto ao cidadão, nas
    # palavras dele; um rótulo por motivo, na ordem de ARCHIVE_REASONS.
    ARCHIVE_REASON_CITIZEN_LABELS = {
      "duplicate" => "Já existe outra manifestação com o mesmo pedido.",
      "no_complement" => "O complemento pedido não chegou no prazo.",
      "lack_of_clarity" => "Faltaram informações para entender o pedido.",
      "lack_of_civility" => "A manifestação usou linguagem ofensiva.",
      "improper" => "O pedido não é assunto da Ouvidoria da Saúde.",
      "loss_of_object" => "O motivo do pedido deixou de existir.",
      "forwarded_elsewhere" => "O pedido é de outro órgão e foi encaminhado a ele."
    }.freeze
    FORWARDING_STATES = %w[pending replied declined cancelled].freeze
    # Cores do prazo (Ombudsman::Deadlines.color_sql / color); estado final não tem cor.
    COLORS = %w[green yellow red paused].freeze
    EVENT_KINDS = %w[
      received classified forwarded forwarding_cancelled forwarding_replied forwarding_declined
      forwarding_extended complement_requested complement_received extended interim_response
      final_response archived reopen_requested reopen_rejected reopened resolution_changed
      identity_consent_recorded
    ].freeze
    CITIZEN_EVENT_KINDS = %w[
      received complement_requested complement_received extended interim_response final_response
      archived reopen_requested reopen_rejected reopened
    ].freeze
    NOTICE_KINDS = %w[interim_response complement_requested final_response archived reopen_decided].freeze
    MET = %w[yes partly no].freeze
    SCORE = (1..5)
    BODY = (20..4000)
    EXTRACT = (20..4000)
    TEXT = (10..4000)
    JUSTIFICATION = (10..500)
    REOPEN_REASON = (10..2000)
    NAME = (2..80)
    FILENAME = (1..120)
    OUVIDORSUS_NUMBER_MAX = 40
    EXTERNAL_BODY_MAX = 120
    REPORT_TEXT_MAX = 8000
    MANIFESTANT_NAME = (2..120)
    MANIFESTANT_CONTACT_MAX = 120
    MAX_ATTACHMENTS = 3
    REOPEN_WINDOW_DAYS = 30
    SATISFACTION_WINDOW_DAYS = 30
    ANONYMOUS_MAX_BODY_BYTES = 16_384
    ANONYMOUS_KEYS = %w[body health_unit_id].freeze
    ROLES = %w[ombudsman ombudsman_staff ombudsman_responder].freeze
    FILE_PURPOSE = "ombudsman_attachment".freeze
    DOMAIN_EVENTS = %w[
      ombudsman.manifestation_received ombudsman.forwarded ombudsman.forwarding_replied
      ombudsman.concluded ombudsman.reopened ombudsman.identity_viewed ombudsman.anonymous_cap_reached
    ].freeze
    SMS_TEXT = "Rota Saúde: há novidade na sua manifestação à Ouvidoria da Saúde. Veja no canal do cidadão.".freeze
  end
end
