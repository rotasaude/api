# Regras condicionais das fichas de cadastro do LEDI 8.7.0 (módulo 24a, ADR
# 0042; contrato §15.3, §15.4 e L17). Recebe as seções já convertidas pelo
# TerritoryRegistry::Dictionary e devolve a PRIMEIRA recusa com o caminho do
# campo (como o módulo 22) — nunca o valor. Uma linha por regra, com o campo
# LEDI no comentário (texto oficial nos comentários do YAML). Fonte única: o
# dashboard espelha estas regras.
module TerritoryRegistry
  module Rules
    # tipoDeImovel (domínio tipo_de_imovel, contrato §15.4).
    HOME = "1".freeze
    INSTITUTION_TYPES = %w[7 8 9 10 11].freeze
    NO_LIVING_CONDITIONS_TYPES = %w[2 3 4 5 6 12 13 99].freeze
    # Campos de condicaoMoradia proibidos por tipo de imóvel (07–11 e, salvo a
    # situação de moradia, 13 CASAI — que já não admite condicaoMoradia).
    FORBIDDEN_BY_TYPE = {
      "area_producao_rural" => %w[7 8 9 10 11 13],
      "material_predominante_paredes_ext_domicilio" => %w[7 8 9 10 11 13],
      "nu_comodos" => %w[7 8 9 10 11 13],
      "tipo_acesso_domicilio" => %w[7 8 9 10 11 13],
      "tipo_domicilio" => %w[7 8 9 10 11 13],
      "situacao_moradia_posse_terra" => %w[7 8 9 10 11]
    }.freeze
    ANIMAL_FIELDS = %w[st_animais_no_domicilio animais_no_domicilio quantos_animais_no_domicilio].freeze
    URBAN_LOCATIONS = [ 83, 205 ].freeze # localizacao 83 Urbana, 205 Periurbana
    BRAZIL = 31                          # paisNascimento 31 BRASIL
    MAX_AGE_YEARS = 130
    EMAIL = /\A[^@\s]+@[^@\s.]+(\.[^@\s.]+)+\z/
    PHONE = /\A\d{10,11}\z/
    MEMBERS = (1..999)

    module_function

    # input: { identification:, sociodemographic:, health_conditions:,
    # street_situation:, refused:, is_responsible: } (seções = values do
    # Dictionary.parse). person: { sex:, birth_date:, race_color:, ethnicity:,
    # has_cpf:, mother_name_present: } — o que mora no paciente (§15.3).
    # has_cpf não recusa nada aqui: CPF × CNS (nunca juntos; CNS sem CPF) é
    # da ficha — sem os dois ela fica "não gerada" (patient_without_identifier,
    # Desvio 7), e o cadastro grava.
    def individual(input, person:, on:)
      input = input.to_h.symbolize_keys
      person = person.to_h.symbolize_keys
      refused = input[:refused] == true

      failure = ethnicity_failure(person)
      return failure if failure

      path = demographics(person, refused, on) ||
             identification(values(input[:identification]), person, refused, on) ||
             refusal(input, refused) ||
             (sociodemographic(values(input[:sociodemographic]), input[:is_responsible], person, on) unless refused) ||
             (health_conditions(values(input[:health_conditions]), person, on) unless refused) ||
             (street_situation(values(input[:street_situation])) unless refused)
      path ? refuse(:invalid_registration, path) : Result.ok
    end

    # input: { property_type:, living_conditions:, refused:, contact_phone? };
    # families: [{ members_count:, responsible_patient_id? }] — as famílias
    # ativas do domicílio (com a nova, na gravação de família).
    def household(input, families:)
      input = input.to_h.symbolize_keys
      families = families.map { |family| family.to_h.symbolize_keys }
      type = input[:property_type]
      refused = input[:refused] == true
      living = values(input[:living_conditions])

      path = household_shape(type, living, refused, families, input[:contact_phone]) ||
             (living_conditions(living, type, families) if living.any?)
      path ? refuse(:invalid_household, path) : Result.ok
    end

    # input: { members_count:, income_band:, living_since: } (FamiliaRow).
    def family(input, property_type:, on: Time.zone.today)
      input = input.to_h.symbolize_keys
      count = input[:members_count]
      income = input[:income_band]
      since = input[:living_since]
      path =
        # familias: só pode ser preenchido se tipoDeImovel = 01 Domicílio
        ("property_type" if property_type != HOME) ||
        # numeroMembrosFamilia: diferente de 0, até 3 dígitos
        ("members_count" if !count.nil? && !(count.is_a?(Integer) && MEMBERS.cover?(count))) ||
        # rendaFamiliar: domínio renda_familiar
        ("income_band" if !income.nil? && !income_bands.include?(income)) ||
        # resideDesde: mês/ano, não pode ser no futuro
        ("living_since" if !since.nil? && !month_until?(since, on))
      path ? refuse(:invalid_family, path) : Result.ok
    end

    # --- individual ----------------------------------------------------------

    # etnia (L17; §15.2): só se aplica a raça/cor 05 (Indígena) e então só com
    # código LEDI — sem ele a ficha não pode sair. Com outra raça/cor a etnia
    # não vai na ficha e não é validada aqui.
    def ethnicity_failure(person)
      return nil unless person[:race_color] == "05"
      return nil if Catalog.ethnicity_to_ledi(person[:ethnicity])

      refuse(:invalid_ethnicity, "patient_demographics.ethnicity")
    end

    def demographics(person, refused, on)
      birth = date(person[:birth_date])
      race = person[:race_color]
      # dataNascimentoCidadao: obrigatório; não posterior ao atendimento nem mais de 130 anos antes
      ("birth_date" if (birth.nil? && !refused) || (birth && (birth > on || birth < on.prev_year(MAX_AGE_YEARS)))) ||
        # racaCorCidadao: obrigatório (códigos do paciente, traduzidos na ficha)
        ("patient_demographics.race_color" if (race.nil? && !refused) || (race && !Catalog::RACE_TO_LEDI.key?(race)))
    end

    # Com recusa (statusTermoRecusaCadastroIndividualAtencaoBasica) a
    # identificação fica opcional: as proibições valem, as obrigações não.
    def identification(id, person, refused, on)
      required = !refused
      nat = id["nacionalidade_cidadao"]
      birth = date(person[:birth_date])
      at = ->(key) { "identification.#{key}" }
      # nacionalidadeCidadao: obrigatório
      (at["nacionalidade_cidadao"] if required && blank?(id["nacionalidade_cidadao"])) ||
        # codigoIbgeMunicipioNascimento: só com nacionalidadeCidadao = 1, e então obrigatório
        (at["codigo_ibge_municipio_nascimento"] if only_and_always(id, "codigo_ibge_municipio_nascimento", nat == 1, required)) ||
        # paisNascimento: só com nacionalidadeCidadao = 3 (obrigatório); com 1, só 31 (BRASIL)
        (at["pais_nascimento"] if present?(id["pais_nascimento"]) && !(nat == 3 || (nat == 1 && id["pais_nascimento"] == BRAZIL))) ||
        (at["pais_nascimento"] if required && nat == 3 && blank?(id["pais_nascimento"])) ||
        # dtNaturalizacao: só com nacionalidadeCidadao = 2 (obrigatório); entre o nascimento e o atendimento
        (at["dt_naturalizacao"] if only_and_always(id, "dt_naturalizacao", nat == 2, required)) ||
        (at["dt_naturalizacao"] if outside?(id["dt_naturalizacao"], birth, on)) ||
        # portariaNaturalizacao: só com nacionalidadeCidadao = 2, e então obrigatório
        (at["portaria_naturalizacao"] if only_and_always(id, "portaria_naturalizacao", nat == 2, required)) ||
        # dtEntradaBrasil: só com nacionalidadeCidadao = 3 (obrigatório); entre o nascimento e o atendimento
        (at["dt_entrada_brasil"] if only_and_always(id, "dt_entrada_brasil", nat == 3, required)) ||
        (at["dt_entrada_brasil"] if outside?(id["dt_entrada_brasil"], birth, on)) ||
        # telefoneCelular: obrigatório com nacionalidade brasileira ou naturalizado
        (at["telefone_celular"] if required && [ 1, 2 ].include?(nat) && blank?(id["telefone_celular"])) ||
        # nomePaiCidadao: proibido com desconheceNomePai = true; obrigatório sem ele
        (at["nome_pai_cidadao"] if id["desconhece_nome_pai"] == true && present?(id["nome_pai_cidadao"])) ||
        (at["nome_pai_cidadao"] if required && id["desconhece_nome_pai"] != true && blank?(id["nome_pai_cidadao"])) ||
        # nomeMaeCidadao (no paciente): proibido com desconheceNomeMae = true; obrigatório sem ele
        (at["desconhece_nome_mae"] if id["desconhece_nome_mae"] == true && person[:mother_name_present]) ||
        ("mother_name" if required && id["desconhece_nome_mae"] != true && !person[:mother_name_present]) ||
        # emailCidadao: padrão endereco@domínio.extensao
        (at["email_cidadao"] if present?(id["email_cidadao"]) && !id["email_cidadao"].to_s.match?(EMAIL))
    end

    # Com recusa ficam proibidos condicoesDeSaude, emSituacaoDeRua e
    # informacoesSocioDemograficas/SocioEconomicas (seção sociodemographic).
    def refusal(input, refused)
      return nil unless refused

      %i[sociodemographic health_conditions street_situation].find { |key| values(input[key]).any? }&.to_s
    end

    def sociodemographic(s, is_responsible, person, on)
      age = age(date(person[:birth_date]), on)
      at = ->(key) { "sociodemographic.#{key}" }
      # statusDesejaInformarOrientacaoSexual: obrigatório
      (at["status_deseja_informar_orientacao_sexual"] if blank?(s["status_deseja_informar_orientacao_sexual"])) ||
        # statusDesejaInformarIdentidadeGenero: obrigatório
        (at["status_deseja_informar_identidade_genero"] if blank?(s["status_deseja_informar_identidade_genero"])) ||
        # deficienciasCidadao: pelo menos um item com statusTemAlgumaDeficiencia = true; proibido com false
        (at["deficiencias_cidadao"] if list_rule(s, "deficiencias_cidadao", s["status_tem_alguma_deficiencia"])) ||
        # orientacaoSexualCidadao: obrigatório com statusDesejaInformarOrientacaoSexual = true; proibido com false
        (at["orientacao_sexual_cidadao"] if list_rule(s, "orientacao_sexual_cidadao", s["status_deseja_informar_orientacao_sexual"])) ||
        # identidadeGeneroCidadao: obrigatório com statusDesejaInformarIdentidadeGenero = true; proibido com false
        (at["identidade_genero_cidadao"] if list_rule(s, "identidade_genero_cidadao", s["status_deseja_informar_identidade_genero"])) ||
        # relacaoParentescoCidadao: só com statusEhResponsavel = false
        (at["relacao_parentesco_cidadao"] if present?(s["relacao_parentesco_cidadao"]) && is_responsible != false) ||
        # responsavelPorCrianca: proibido a partir de 10 anos na data do atendimento
        (at["responsavel_por_crianca"] if present?(s["responsavel_por_crianca"]) && age && age >= 10) ||
        # coPovoComunidadeTradicional: proibido com statusMembroPovoComunidadeTradicional = false
        (at["co_povo_comunidade_tradicional"] if forbidden_when_false(s, "co_povo_comunidade_tradicional", "status_membro_povo_comunidade_tradicional")) ||
        # alimentosAcabaram... e comeuAlgunsAlimentos...: um só com o outro, e então obrigatório
        (at["alimentos_acabaram_antes_ter_dinheiro_comprar_mais"] if
          present?(s["comeu_alguns_alimentos_que_tinha_dinheiro_acabou"]) && blank?(s["alimentos_acabaram_antes_ter_dinheiro_comprar_mais"])) ||
        (at["comeu_alguns_alimentos_que_tinha_dinheiro_acabou"] if
          present?(s["alimentos_acabaram_antes_ter_dinheiro_comprar_mais"]) && blank?(s["comeu_alguns_alimentos_que_tinha_dinheiro_acabou"]))
    end

    def health_conditions(h, person, on)
      age = age(date(person[:birth_date]), on)
      at = ->(key) { "health_conditions.#{key}" }
      # statusEhGestante: proibido para sexo 0 (masculino) e fora de 9–60 anos
      (at["status_eh_gestante"] if present?(h["status_eh_gestante"]) && (person[:sex] == "male" || age.nil? || age < 9 || age > 60)) ||
        # maternidadeDeReferencia: proibido com statusEhGestante = false
        (at["maternidade_de_referencia"] if forbidden_when_false(h, "maternidade_de_referencia", "status_eh_gestante")) ||
        # doencaCardiaca: pelo menos um item com statusTeveDoencaCardiaca = true; proibido com false
        (at["doenca_cardiaca"] if list_rule(h, "doenca_cardiaca", h["status_teve_doenca_cardiaca"])) ||
        # doencaRespiratoria: pelo menos um item com statusTemDoencaRespiratoria = true; proibido com false
        (at["doenca_respiratoria"] if list_rule(h, "doenca_respiratoria", h["status_tem_doenca_respiratoria"])) ||
        # doencaRins: pelo menos um item com statusTemTeveDoencasRins = true; proibido com false
        (at["doenca_rins"] if list_rule(h, "doenca_rins", h["status_tem_teve_doencas_rins"])) ||
        # descricaoCausaInternacaoEm12Meses: proibido com statusTeveInternadoem12Meses = false
        (at["descricao_causa_internacao_em12_meses"] if
          forbidden_when_false(h, "descricao_causa_internacao_em12_meses", "status_teve_internado_em12_meses")) ||
        # descricaoPlantasMedicinaisUsadas: proibido com statusUsaPlantasMedicinais = false
        (at["descricao_plantas_medicinais_usadas"] if forbidden_when_false(h, "descricao_plantas_medicinais_usadas", "status_usa_planta_medicinais"))
    end

    def street_situation(r)
      at = ->(key) { "street_situation.#{key}" }
      off_street = r["status_situacao_rua"] == false
      # statusSituacaoRua: obrigatório sem recusa
      (at["status_situacao_rua"] if blank?(r["status_situacao_rua"])) ||
        # demais campos de emSituacaoDeRua: proibidos com statusSituacaoRua = false
        (street_fields.find { |key| present?(r[key]) }&.then { at[_1] } if off_street) ||
        # grauParentescoFamiliarFrequentado: proibido com statusVisitaFamiliarFrequentemente = false
        (at["grau_parentesco_familiar_frequentado"] if
          forbidden_when_false(r, "grau_parentesco_familiar_frequentado", "status_visita_familiar_frequentemente")) ||
        # higienePessoalSituacaoRua: pelo menos um item com statusTemAcessoHigienePessoalSituacaoRua = true
        (at["higiene_pessoal_situacao_rua"] if r["status_tem_acesso_higiene_pessoal_situacao_rua"] == true && blank?(r["higiene_pessoal_situacao_rua"])) ||
        # outraInstituicaoQueAcompanha: proibido com statusAcompanhadoPorOutraInstituicao = false
        (at["outra_instituicao_que_acompanha"] if forbidden_when_false(r, "outra_instituicao_que_acompanha", "status_acompanhado_por_outra_instituicao"))
    end

    # --- domicílio -----------------------------------------------------------

    def household_shape(type, living, refused, families, phone)
      responsibles = families.filter_map { |family| family[:responsible_patient_id] }
      # tipoDeImovel: obrigatório, domínio tipo_de_imovel
      ("property_type" unless Catalog::PROPERTY_TYPES.include?(type)) ||
        # condicaoMoradia: proibido com statusTermoRecusa = true
        ("living_conditions" if refused && living.any?) ||
        # familias: proibido com statusTermoRecusa = true
        ("families" if refused && families.any?) ||
        # familias: só com tipoDeImovel = 01 Domicílio
        ("families" if type != HOME && families.any?) ||
        # familias: não podem ser cadastradas famílias com o mesmo responsável
        ("families" if responsibles.uniq.size != responsibles.size) ||
        # condicaoMoradia: proibido para 02, 03, 04, 05, 06, 12, 13 e 99
        ("living_conditions" if NO_LIVING_CONDITIONS_TYPES.include?(type) && living.any?) ||
        # telefoneContato: 10 a 11 dígitos
        ("contact_phone" if !phone.nil? && !phone.to_s.match?(PHONE)) ||
        # instituicaoPermanencia: obrigatória em 07–11 sem recusa (L6); só pode em 07–11
        ("living_conditions.instituicao_permanencia" if INSTITUTION_TYPES.include?(type) && !refused && blank?(living["instituicao_permanencia"])) ||
        ("living_conditions.instituicao_permanencia" if !INSTITUTION_TYPES.include?(type) && present?(living["instituicao_permanencia"]))
    end

    def living_conditions(l, type, families)
      at = ->(key) { "living_conditions.#{key}" }
      residents = families.sum { |family| family[:members_count] || 1 }
      animals = Array(l["animais_no_domicilio"])
      # localizacao: obrigatório
      (at["localizacao"] if blank?(l["localizacao"])) ||
        # situacaoMoradiaPosseTerra: obrigatório, salvo 07–11 (onde é proibido)
        (at["situacao_moradia_posse_terra"] if !INSTITUTION_TYPES.include?(type) && blank?(l["situacao_moradia_posse_terra"])) ||
        # areaProducaoRural, materialPredominante..., nuComodos, tipoAcessoDomicilio, tipoDomicilio: proibidos em 07–11 e 13;
        # situacaoMoradiaPosseTerra: proibido em 07–11
        FORBIDDEN_BY_TYPE.find { |key, types| types.include?(type) && present?(l[key]) }&.then { at[_1.first] } ||
        # stAnimaisNoDomicilio, animaisNoDomicilio, quantosAnimaisNoDomicilio: só com tipoDeImovel = 01
        (ANIMAL_FIELDS.find { |key| present?(l[key]) }&.then { at[_1] } if type != HOME) ||
        # animaisNoDomicilio: proibido com stAnimaisNoDomicilio = false
        (at["animais_no_domicilio"] if forbidden_when_false(l, "animais_no_domicilio", "st_animais_no_domicilio")) ||
        # quantosAnimaisNoDomicilio: proibido com stAnimaisNoDomicilio = false; ≥ opções de animaisNoDomicilio
        (at["quantos_animais_no_domicilio"] if forbidden_when_false(l, "quantos_animais_no_domicilio", "st_animais_no_domicilio")) ||
        (at["quantos_animais_no_domicilio"] if present?(l["quantos_animais_no_domicilio"]) && l["quantos_animais_no_domicilio"] < animals.size) ||
        # areaProducaoRural: proibido com localizacao = 83 Urbana ou 205 Periurbana
        (at["area_producao_rural"] if present?(l["area_producao_rural"]) && URBAN_LOCATIONS.include?(l["localizacao"])) ||
        # tipoOrigemEnergiaEletrica: proibido com stDisponibilidadeEnergiaEletrica = false
        (at["tipo_origem_energia_eletrica"] if forbidden_when_false(l, "tipo_origem_energia_eletrica", "st_disponibilidade_energia_eletrica")) ||
        # nuMoradores: ≥ número de famílias e ≥ Σ numeroMembrosFamilia (1 quando não informado)
        (at["nu_moradores"] if present?(l["nu_moradores"]) && l["nu_moradores"] < [ families.size, residents ].max)
    end

    # --- apoio ---------------------------------------------------------------

    def present?(value) = !blank?(value)
    def blank?(value) = value.nil? || value == "" || value == [] || value == {}

    # Seção já convertida (Hash de chaves texto), {} quando ausente.
    def values(section) = section.is_a?(Hash) ? section.stringify_keys : {}

    # Só com a condição, e então obrigatório (quando a identificação é exigida).
    def only_and_always(values, key, condition, required)
      condition ? required && blank?(values[key]) : present?(values[key])
    end

    # Lista (ou código) obrigatória com o status true e proibida com false.
    def list_rule(values, key, status)
      (status == true && blank?(values[key])) || (status == false && present?(values[key]))
    end

    def forbidden_when_false(values, key, status_key) = values[status_key] == false && present?(values[key])

    # Data fora do intervalo [nascimento, atendimento].
    def outside?(value, birth, on)
      day = date(value)
      day && (day > on || (birth && day < birth))
    end

    def street_fields = Dictionary.section("street_situation").keys - %w[status_situacao_rua]

    def income_bands = Dictionary.domain("renda_familiar").keys.map(&:to_s)

    def month_until?(value, on)
      month = Dictionary.month(value)
      month && Date.iso8601("#{month}-01") <= on.beginning_of_month
    end

    def date(value)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s) if value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    rescue Date::Error
      nil
    end

    # Idade em anos completos na data do atendimento.
    def age(birth, on)
      return nil unless birth

      on.year - birth.year - ((on.month > birth.month || (on.month == birth.month && on.day >= birth.day)) ? 0 : 1)
    end

    def refuse(reason, path) = Result.fail(reason, details: { path: path })

    private_class_method :ethnicity_failure, :demographics, :identification, :refusal, :sociodemographic, :health_conditions,
                         :street_situation, :household_shape, :living_conditions, :present?, :blank?, :values, :only_and_always,
                         :list_rule, :forbidden_when_false, :outside?, :street_fields, :income_bands, :month_until?, :date, :age, :refuse
  end
end
