# Ficha de Cadastro Individual (tipoDadoSerializado 2; módulo 24a, ADR 0042;
# contrato §15.1–§15.3). Pura: recebe valores já decifrados da versão
# (Ledi::IndividualRegistrationFicha monta). Implementa Ledi::Ficha.
#   values: "identity" (o retrato do paciente: full_name, social_name,
#   birth_date, sex, race_color, ethnicity, mother_name, cpf, cns,
#   no_cpf_reason), "identification", "sociodemographic", "health_conditions",
#   "street_situation" (seções do dicionário), "refused", "micro_area_code"
#   (nil = fora de área), "is_responsible", "responsible" ({ cpf, cns } do
#   responsável da família, só quando não é ele), "exit" ({ reason, on,
#   death_on, death_certificate } ou nil).
# Traduções do §15.2: raça/cor e sexo pelo Catalog; etnia só com raça/cor 05
# (Catalog.ethnicity_to_ledi; L17). CPF ou CNS, nunca os dois. Com recusa,
# só a identificação. Nomes no conjunto do "Validar nome" (LediName).
module Ledi
  module Fichas
    class IndividualRegistration
      ORIGIN_THIRD_PARTY = 3
      BRAZIL = 31
      BRAZILIAN = 1
      INDIGENOUS = "05"
      SOURCE_TYPE = "IndividualRegistrationVersion".freeze
      C = TerritoryRegistry::Catalog
      D = TerritoryRegistry::Dictionary
      F = RegistrationFields

      attr_reader :header, :source_id

      def initialize(header:, values:, originating_uuid:, source_id:)
        @header, @values, @originating_uuid, @source_id = header, values.deep_stringify_keys, originating_uuid, source_id
      end

      def type = "cadastro_individual"
      def competence = header.competence
      def cnes = header.cnes
      def ine = header.ine
      def source = { type: SOURCE_TYPE, id: source_id }

      # Dado de saúde e identidade: nunca em inspect/log/JSON.
      def inspect = "#<#{self.class.name} source_id=#{source_id}>"
      alias to_s inspect
      def pretty_print(q) = q.text(inspect)
      def as_json(*) = { "type" => type, "source_id" => source_id }

      def to_thrift(uuid:)
        Ledi::Version.load!
        ci = Br::Gov::Saude::Esusab::Ras::Cadastroindividual
        refused = @values["refused"] == true
        attrs = {
          uuid: uuid, tpCdsOrigem: ORIGIN_THIRD_PARTY, fichaAtualizada: !@originating_uuid.nil?,
          uuidFichaOriginadora: @originating_uuid || uuid, headerTransport: header.to_thrift,
          statusTermoRecusaCadastroIndividualAtencaoBasica: refused, identificacaoUsuarioCidadao: identification(ci)
        }
        attrs.merge!(sections(ci)) unless refused
        ci::CadastroIndividualThrift.new(**attrs)
      end

      private

      def identification(ci)
        identity = @values.fetch("identity").to_h
        section = @values["identification"].to_h
        attrs = F.split(D.section("identification"), section, [ ci::IdentificacaoUsuarioCidadaoThrift ])
                 .fetch(ci::IdentificacaoUsuarioCidadaoThrift)
        attrs.merge!(person(identity, section), document(identity), responsibility, area)
        # paisNascimento: 31 (BRASIL) com nacionalidade brasileira (o Rules recusa outro).
        attrs["paisNascimento"] = BRAZIL if section["nacionalidade_cidadao"] == BRAZILIAN
        ci::IdentificacaoUsuarioCidadaoThrift.new(**attrs.compact.symbolize_keys)
      end

      def person(identity, section)
        race = identity["race_color"]
        {
          "nomeCidadao" => LediName.call(identity["full_name"]), "nomeSocial" => LediName.call(identity["social_name"]),
          "dataNascimentoCidadao" => identity["birth_date"].presence && F.epoch_ms(identity["birth_date"]),
          "sexoCidadao" => C::SEX_TO_LEDI[identity["sex"]], "racaCorCidadao" => C::RACE_TO_LEDI[race],
          "etnia" => (C.ethnicity_to_ledi(identity["ethnicity"]) if race == INDIGENOUS),
          "nomeMaeCidadao" => (LediName.call(identity["mother_name"]) unless section["desconhece_nome_mae"] == true)
        }
      end

      # CPF; sem CPF, o CNS com stNaoPossuiCpf e a justificativa.
      def document(identity)
        cpf = identity["cpf"].presence
        return { "cpfCidadao" => cpf, "stNaoPossuiCpf" => false } if cpf

        reason = identity["no_cpf_reason"].presence
        { "cnsCidadao" => identity["cns"].presence, "stNaoPossuiCpf" => true, "justificativaNaoPossuiCpf" => reason&.to_i }
      end

      def responsibility
        responsible = @values["is_responsible"] == true
        return { "statusEhResponsavel" => true } if responsible

        other = @values["responsible"].to_h
        cpf = other["cpf"].presence
        { "statusEhResponsavel" => false, "cpfResponsavelFamiliar" => cpf, "cnsResponsavelFamiliar" => (other["cns"].presence unless cpf) }
      end

      def area
        code = @values["micro_area_code"].presence
        { "microArea" => code, "stForaArea" => code.nil? }
      end

      def sections(ci)
        socio = F.split(D.section("sociodemographic"), @values["sociodemographic"].to_h,
                        [ ci::InformacoesSocioDemograficasThrift, ci::InformacoesSocioEconomicasThrift ])
        {
          condicoesDeSaude: F.build(ci::CondicoesDeSaudeThrift, D.section("health_conditions"), @values["health_conditions"].to_h),
          emSituacaoDeRua: F.build(ci::EmSituacaoDeRuaThrift, D.section("street_situation"), @values["street_situation"].to_h),
          informacoesSocioDemograficas: struct(ci::InformacoesSocioDemograficasThrift, socio),
          informacoesSocioEconomicas: struct(ci::InformacoesSocioEconomicasThrift, socio),
          saidaCidadaoCadastro: exit_section(ci)
        }
      end

      def struct(klass, split)
        attrs = split.fetch(klass)
        attrs.empty? ? nil : klass.new(**attrs.symbolize_keys)
      end

      # dataObito e numeroDO só (e dataObito sempre) com 135 Óbito.
      def exit_section(ci)
        exit = @values["exit"].presence or return nil
        code = C::LEDI_EXIT.fetch(exit.fetch("reason"))
        death = code == C::LEDI_EXIT.fetch("death")
        died_on = exit["death_on"].presence || exit["on"]
        ci::SaidaCidadaoCadastroThrift.new(motivoSaidaCidadao: code, dataObito: (F.epoch_ms(died_on) if death),
                                           numeroDO: (exit["death_certificate"].presence if death))
      end
    end
  end
end
