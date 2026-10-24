# Códigos fixos do cadastro territorial (módulo 24a, ADR 0042). Os domínios das
# fichas moram em config/ledi/registration_dictionaries.yml (prova técnica,
# Task 0); aqui só o que o código usa pelo nome.
module TerritoryRegistry
  module Catalog
    ACS_CBO = "515105"
    ENDEMIC_AGENT_CBO = "515140"
    REGISTRAR_CBO_PREFIXES = %w[2235 2251 2252 2253].freeze
    # Equipes que têm microárea (contrato §3): eSF (70) e eAP (76). Fixo aqui,
    # não HealthTeam::KINDS: um tipo novo vindo do CNES não ganha microárea.
    TEAM_KINDS = %w[70 76].freeze
    VALIDITY_MONTHS = 24
    DUE_SOON_DAYS = 60
    EXIT_REASONS = %w[moved death].freeze
    LEDI_EXIT = { "death" => 135, "moved" => 136 }.freeze
    NO_CPF_REASONS = %w[2 3 4 5 6 7 8 9 10 11 12 13].freeze
    PROPERTY_TYPES = %w[1 2 3 4 5 6 7 8 9 10 11 12 13 99].freeze
    INCOME_BANDS = %w[1 2 3 4 5 6 7 8].freeze
    # O paciente guarda raça/cor nos códigos do BPA (módulo 22: 03 Parda, 04
    # Amarela); a ficha LEDI usa 4 Parda e 3 Amarela.
    RACE_TO_LEDI = { "01" => 1, "02" => 2, "03" => 4, "04" => 3, "05" => 5 }.freeze
    # O paciente guarda a etnia no código CADSUS de 4 dígitos (BPA); a ficha usa
    # o código LEDI, igual ao CADSUS de 0001 a 0264, com duas exceções: 0304
    # (PURI) é 406 e 0315 (WARAO) é 407 — no LEDI, 304 e 315 são outras etnias.
    ETHNICITY_EXCEPTIONS_TO_LEDI = { "0304" => 406, "0315" => 407 }.freeze
    SEX_TO_LEDI = { "male" => 0, "female" => 1 }.freeze
    # O CityProfile guarda a sigla da UF ("PR"); o numeroDneUf da ficha
    # domiciliar é o código texto do DNE (string_domains.uf do dicionário:
    # Paraná = "17"), achado pelo nome da UF.
    UF_NAMES = {
      "AC" => "ACRE", "AL" => "ALAGOAS", "AP" => "AMAPÁ", "AM" => "AMAZONAS", "BA" => "BAHIA", "CE" => "CEARÁ",
      "DF" => "DISTRITO FEDERAL", "ES" => "ESPÍRITO SANTO", "RR" => "RORAIMA", "GO" => "GOIÁS", "MA" => "MARANHÃO",
      "MT" => "MATO GROSSO", "MS" => "MATO GROSSO DO SUL", "MG" => "MINAS GERAIS", "PA" => "PARÁ", "PB" => "PARAÍBA",
      "PR" => "PARANÁ", "PE" => "PERNAMBUCO", "PI" => "PIAUÍ", "RJ" => "RIO DE JANEIRO", "RN" => "RIO GRANDE DO NORTE",
      "RS" => "RIO GRANDE DO SUL", "RO" => "RONDÔNIA", "TO" => "TOCANTINS", "SC" => "SANTA CATARINA", "SP" => "SÃO PAULO",
      "SE" => "SERGIPE"
    }.freeze
    UF_TO_DNE = UF_NAMES.transform_values { |name| Dictionary.string_domain("uf").key(name) || raise(KeyError, name) }.freeze
    # Situação do cadastro (contrato §1; §14 L5: missing_identifier = cadastro
    # gravado sem CPF e sem CNS; TerritoryRegistry::Validity decide).
    STATUSES = %w[valid due_soon expired missing missing_identifier refused exited].freeze
    VERSION_ORIGINS = %w[save identity_refresh exit].freeze

    module_function

    # nil = etnia sem código LEDI (a ficha não pode sair com ela).
    def ethnicity_to_ledi(code)
      return ETHNICITY_EXCEPTIONS_TO_LEDI[code] if ETHNICITY_EXCEPTIONS_TO_LEDI.key?(code)
      number = code.to_s.match?(/\A\d{4}\z/) ? code.to_i : nil
      number if number&.between?(1, 264)
    end
  end
end
