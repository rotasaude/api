# Constantes do módulo 28 (ADR 0046): vocabulário fixo da consulta
# odontológica e da FAO. Sem dado pessoal.
module DentalCare
  module Catalog
    KINDS = %w[general dental].freeze
    DENTIST_PREFIX = "2232".freeze
    AUXILIARY_CBOS = %w[322405 322415 322425 322430].freeze

    CARE_TYPES = [ 2, 4, 5, 6 ].freeze
    CARE_TYPE_SCHEDULED = 2
    CARE_TYPE_ORIENTATION = 4
    CARE_TYPE_URGENCY = 6
    CONSULTATION_TYPES = [ 1, 2, 4 ].freeze
    FIRST = 1
    RETURN = 2
    SURVEILLANCE = [ 1, 2, 3, 4, 5, 6, 99 ].freeze
    SUPPLIES = [ 1, 2, 3 ].freeze
    OUTCOMES = [ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 17, 18 ].freeze
    REFERRAL_OUTCOMES = (1..11).to_a.freeze
    COMPLETED = 15
    DISCHARGE = 17
    REFERRAL_SPECIALTIES = {
      1 => %w[223288], 2 => %w[223268], 3 => %w[223212], 4 => %w[223220], 5 => %w[223224],
      6 => %w[223236], 7 => %w[223240], 8 => %w[223248], 9 => %w[223256 223252 223264]
    }.freeze
    PROHIBITED_PROCEDURES = %w[0301040079].freeze
    MAX_PROCEDURE_CODES = 20
    MAX_ITEMS = 200

    PERMANENT_TEETH = [ 11..18, 21..28, 31..38, 41..48 ].flat_map(&:to_a).freeze
    DECIDUOUS_TEETH = [ 51..55, 61..65, 71..75, 81..85 ].flat_map(&:to_a).freeze
    FACES = %w[M D O V L].freeze
    PARTS = %w[crown root].freeze
    SEXTANTS = %w[S1 S2 S3 S4 S5 S6].freeze
    ARCHES = %w[upper lower].freeze
    LOCATION_KINDS = %w[tooth face sextant arch mouth].freeze

    PLAN_STATUSES = %w[open completed cancelled].freeze
    ITEM_STATUSES = %w[planned done cancelled].freeze

    PROSTHESIS_STAGES = %w[impression sent received installed cancelled].freeze
    PROSTHESIS_CODES = %w[0701070099 0701070102 0701070129 0701070137 0701070145].freeze
    LAB_NAME = 3..120

    CEO_TYPES = %w[I II III].freeze
    CEO_SPECIALTIES = %w[endodontics periodontics oral_surgery stomatology special_needs prosthesis].freeze
    ORAL_HEALTH_TEAM_KIND = "71".freeze
    # Semente da lista do TSB/ASB (Valores fixados 4; a migração 20261030900001
    # insere a mesma lista): cariostático, selante, flúor tópico, evidenciação
    # de placa, selamento provisório e raspagem supragengival por sextante.
    AUXILIARY_DEFAULT_PROCEDURES = %w[0101020058 0101020066 0101020074 0101020082 0101020090 0307030059].freeze

    REASON = 10..500

    PERIO_SITES = %w[MV V DV ML L DL].freeze
    PROBING_MM = 0..20
    RECESSION_MM = -10..20
    MOBILITY = 0..3
    FURCATION = 0..3
    SCREENING_CODES = 0..4

    CANALS = 1..5
    ENDO_STATUSES = %w[in_progress completed].freeze

    TRAIL_SCOPE = "dental".freeze
    PREGNANCY_TEMPLATE = "pregnancy_c3".freeze
  end
end
