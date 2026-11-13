# Ficha de Visita Domiciliar e Territorial (tipoDadoSerializado 8; módulo 24b,
# ADR 0052; contrato §10). Pura: recebe o cabeçalho, o dia e as visitas já
# decifradas (Ledi::HomeVisitDayFicha monta, na ordem de occurred_at, só as não
# retiradas). Implementa Ledi::Ficha.
#   visits: [{ "shift", "outcome", "reasons" ([Integer]), "shared",
#   "property_type" (texto), "micro_area_code" (nil fora de área), "out_of_area",
#   "measurements" ({ chave do §3 => número }), "household_origin_uuid" (nil sem
#   ficha utilizável do domicílio), "person" (nil sem pessoa: { "cpf", "cns",
#   "no_cpf", "justification", "birth_date" (ISO), "sex" (0/1 do LEDI) }) }].
# CPF xor CNS (Ledi::Fichas::CitizenDocument); nascimento às 00h no fuso da
# cidade, como o dataAtendimento (o dicionário o quer ≤ dataAtendimento). Nunca
# numProntuario, latitude, longitude nem ivcf. Medidas pelo nome do IDL, lido de
# config/ledi/visit_activity_dictionaries.yml (`ledi`), no tipo do campo Thrift.
module Ledi
  module Fichas
    HomeVisitDay = Data.define(:header, :day, :visits, :source_id) do
      def type = "visita_domiciliar"
      def competence = day.strftime("%Y%m")
      def cnes = header.cnes
      def ine = header.ine
      def source = { type: HomeVisitDay::SOURCE_TYPE, id: source_id }

      # Documento, nascimento, motivos e medidas: nunca em inspect/log/JSON.
      def inspect = "#<#{self.class.name} source_id=#{source_id}>"
      alias_method :to_s, :inspect
      def pretty_print(q) = q.text(inspect)
      def as_json(*) = { "type" => type, "source_id" => source_id }

      def to_thrift(uuid:)
        Ledi::Version.load!
        vd = Br::Gov::Saude::Esusab::Ras::Visitadomiciliar
        vd::FichaVisitaDomiciliarMasterThrift.new(
          uuidFicha: uuid, tpCdsOrigem: HomeVisitDay::ORIGIN_THIRD_PARTY, headerTransport: header.to_thrift,
          visitasDomiciliares: visits.map { |row| child(vd::FichaVisitaDomiciliarChildThrift, row) }
        )
      end

      private

      def child(klass, row)
        attrs = {
          turno: row.fetch("shift"), desfecho: row.fetch("outcome"), motivosVisita: Array(row["reasons"]).presence,
          statusVisitaCompartilhadaOutroProfissional: row["shared"] == true, microArea: row["micro_area_code"],
          stForaArea: row["out_of_area"] == true, tipoDeImovel: row.fetch("property_type").to_i,
          uuidOrigemCadastroDomiciliar: row["household_origin_uuid"]
        }
        if (person = row["person"])
          attrs.merge!(cpfCidadao: person["cpf"], cnsCidadao: person["cns"], stCidadaoNaoPossuiCpf: person["no_cpf"],
                       justificativaCidadaoNaoPossuiCpf: person["justification"], sexo: person["sex"],
                       dtNascimento: RegistrationFields.epoch_ms(person.fetch("birth_date")))
        end
        attrs.merge!(measurements(klass, row["measurements"].to_h))
        klass.new(**attrs)
      end

      def measurements(klass, values)
        HomeVisitDay::MEASUREMENTS.each_with_object({}) do |(key, name), attrs|
          value = values[key]
          next if value.nil?

          double = klass::FIELDS.values.find { |field| field[:name] == name }.fetch(:type) == ::Thrift::Types::DOUBLE
          attrs[name.to_sym] = double ? value.to_f : value.to_i
        end
      end
    end

    HomeVisitDay::SOURCE_TYPE = "HomeVisitDay".freeze
    HomeVisitDay::ORIGIN_THIRD_PARTY = 3
    # chave da medida (§3) => campo do FichaVisitaDomiciliarChildThrift.
    HomeVisitDay::MEASUREMENTS = YAML.load_file(Rails.root.join("config/ledi/visit_activity_dictionaries.yml"))
                                     .dig("home_visit", "measurements").transform_values { |spec| spec.fetch("ledi").freeze }.freeze
  end
end
