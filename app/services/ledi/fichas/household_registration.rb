# Ficha de Cadastro Domiciliar e Territorial (tipoDadoSerializado 3; módulo
# 24a, ADR 0042; contrato §15.4). Pura: recebe valores já decifrados da versão
# (Ledi::HouseholdRegistrationFicha monta). Implementa Ledi::Ficha.
#   values: "property_type", "refused", "status" (active|inactive),
#   "micro_area_code", "uf" (sigla do CityProfile), "contact_phone",
#   "address" (TerritoryRegistry::Address, com "district" já resolvido para o
#   nome do bairro do cadastro de bairros), "living_conditions" (seção do
#   dicionário, com instituicao_permanencia), "families" ([{ cpf, cns,
#   birth_date, members_count, income_band, living_since "AAAA-MM",
#   moved_out }]).
# tipoEndereco 3 (logradouro); município pelo IBGE do cabeçalho e UF pelo
# código DNE (Catalog::UF_TO_DNE); famílias e animais só no tipo 1; com recusa,
# nada de moradia, animais nem famílias. Domicílio inativo: o IDL não tem
# stAtivo (§15.5) — vai como atualização com todas as famílias em stMudanca
# (plano, Desvio 9).
module Ledi
  module Fichas
    class HouseholdRegistration
      ORIGIN_THIRD_PARTY = 3
      ADDRESS_TYPE_STREET = 3
      HOME = "1"
      SOURCE_TYPE = "HouseholdVersion".freeze
      C = TerritoryRegistry::Catalog
      D = TerritoryRegistry::Dictionary
      F = RegistrationFields

      attr_reader :header, :source_id

      def initialize(header:, values:, originating_uuid:, source_id:)
        @header, @values, @originating_uuid, @source_id = header, values.deep_stringify_keys, originating_uuid, source_id
      end

      def type = "cadastro_domiciliar"
      def competence = header.competence
      def cnes = header.cnes
      def ine = header.ine
      def source = { type: SOURCE_TYPE, id: source_id }

      # Endereço, moradia, telefone e responsáveis: nunca em inspect/log/JSON.
      def inspect = "#<#{self.class.name} source_id=#{source_id}>"
      alias to_s inspect
      def pretty_print(q) = q.text(inspect)
      def as_json(*) = { "type" => type, "source_id" => source_id }

      def to_thrift(uuid:)
        Ledi::Version.load!
        cd = Br::Gov::Saude::Esusab::Ras::Cadastrodomiciliar
        refused = @values["refused"] == true
        attrs = {
          uuid: uuid, tpCdsOrigem: ORIGIN_THIRD_PARTY, tipoEndereco: ADDRESS_TYPE_STREET, fichaAtualizada: !@originating_uuid.nil?,
          uuidFichaOriginadora: @originating_uuid || uuid, headerTransport: header.to_thrift,
          tipoDeImovel: @values.fetch("property_type").to_i, statusTermoRecusa: refused, enderecoLocalPermanencia: address
        }
        attrs.merge!(living(cd), familias: families(cd)) unless refused
        cd::CadastroDomiciliarThrift.new(**attrs)
      end

      private

      def address
        address = @values["address"].presence or return nil
        no_number = address["no_number"] == true
        Br::Gov::Saude::Esusab::Ras::Common::EnderecoLocalPermanenciaThrift.new(
          bairro: address["district"], cep: address["zip"], codigoIbgeMunicipio: header.ibge_code, complemento: address["complement"],
          nomeLogradouro: address["street"], numero: (address["number"] unless no_number), stSemNumero: no_number,
          numeroDneUf: C::UF_TO_DNE[@values["uf"]], tipoLogradouroNumeroDne: address["street_type"],
          pontoReferencia: address["reference"], telefoneContato: @values["contact_phone"].presence,
          microArea: @values["micro_area_code"].presence, stForaArea: @values["micro_area_code"].blank?
        )
      end

      # condicaoMoradia, animais (no mestre) e instituicaoPermanencia.
      def living(cd)
        section = @values["living_conditions"].to_h
        fields = D.section("living_conditions")
        split = F.split(fields, section, [ cd::CondicaoMoradiaThrift, cd::CadastroDomiciliarThrift ])
        moradia = split.fetch(cd::CondicaoMoradiaThrift)
        institution = section["instituicao_permanencia"].presence &&
                      F.build(cd::InstituicaoPermanenciaThrift, fields.fetch("instituicao_permanencia").fetch("fields"),
                              section["instituicao_permanencia"])
        split.fetch(cd::CadastroDomiciliarThrift).symbolize_keys
             .merge(condicaoMoradia: moradia.empty? ? nil : cd::CondicaoMoradiaThrift.new(**moradia.symbolize_keys),
                    instituicaoPermanencia: institution)
      end

      def families(cd)
        rows = Array(@values["families"])
        return nil if rows.empty? || @values["property_type"].to_s != HOME

        inactive = @values["status"] == "inactive"
        rows.map do |row|
          cpf = row["cpf"].presence
          cd::FamiliaRowThrift.new(
            cpfResponsavel: cpf, numeroCnsResponsavel: (row["cns"].presence unless cpf),
            dataNascimentoResponsavel: row["birth_date"].presence && F.epoch_ms(row["birth_date"]),
            numeroMembrosFamilia: row["members_count"], rendaFamiliar: row["income_band"].presence&.to_i,
            resideDesde: row["living_since"].presence && F.epoch_ms("#{row['living_since']}-01"),
            stMudanca: inactive || row["moved_out"] == true
          )
        end
      end
    end
  end
end
