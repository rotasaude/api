# Ficha de Atividade Coletiva (tipoDadoSerializado 6; módulo 24b, ADR 0052;
# contrato §11). Pura: recebe o cabeçalho, a data e os valores já decifrados
# (Ledi::CollectiveActivityFicha monta). Implementa Ledi::Ficha.
#   values: { "activity_type", "shift", "place_text" | "place_cnes" (um só),
#   "participants_count", "altered_count", "meeting_topics", "target_audience",
#   "health_topics", "health_practices" ([Integer]), "procedure_code" (nil sem
#   a prática 30) }.
#   professionals: [{ "cns", "cbo" }].
#   participants: [{ "cpf", "cns", "no_cpf" (nil sem documento algum),
#   "justification", "birth_date" (ISO), "sex" (0/1 do LEDI), "altered_evaluation",
#   "measurements" ({ "weight_kg", "height_cm" }), "smoking" ({ "quit", "dropped_out" }) }].
# Nunca inep; pseEducacao/pseSaude sempre false e sempre enviados; tbCdsOrigem 3;
# listas vazias não vão. Nascimento às 00h no fuso da cidade, como o
# dataAtendimento. Medidas pelo nome do IDL, lido de
# config/ledi/visit_activity_dictionaries.yml (`participant_measurements`).
module Ledi
  module Fichas
    CollectiveActivity = Data.define(:header, :held_on, :values, :professionals, :participants, :source_id) do
      def type = "atividade_coletiva"
      def competence = held_on.strftime("%Y%m")
      def cnes = header.cnes
      def ine = header.ine
      def source = { type: CollectiveActivity::SOURCE_TYPE, id: source_id }

      # Documento, nascimento, temas, práticas e medidas: nunca em inspect/log/JSON.
      def inspect = "#<#{self.class.name} source_id=#{source_id}>"
      alias_method :to_s, :inspect
      def pretty_print(q) = q.text(inspect)
      def as_json(*) = { "type" => type, "source_id" => source_id }

      def to_thrift(uuid:)
        Ledi::Version.load!
        ac = Br::Gov::Saude::Esusab::Ras::Atividadecoletiva
        ac::FichaAtividadeColetivaThrift.new(
          uuidFicha: uuid, headerTransport: header.to_thrift, tbCdsOrigem: CollectiveActivity::ORIGIN_THIRD_PARTY,
          outraLocalidade: values["place_text"], cnesLocalAtividade: values["place_cnes"],
          numParticipantes: values.fetch("participants_count"), numAvaliacoesAlteradas: values.fetch("altered_count"),
          atividadeTipo: values.fetch("activity_type"), turno: values.fetch("shift"),
          temasParaReuniao: list("meeting_topics"), publicoAlvo: list("target_audience"),
          temasParaSaude: list("health_topics"), praticasEmSaude: list("health_practices"),
          procedimento: values["procedure_code"].presence,
          profissionais: professionals.map { |row| professional(ac::ProfissionalCboRowItemThrift, row) }.presence,
          participantes: participants.map { |row| participant(ac::ParticipanteRowItemThrift, row) }.presence,
          pseEducacao: false, pseSaude: false
        )
      end

      private

      def list(key) = Array(values[key]).map(&:to_i).presence

      def professional(klass, row) = klass.new(cnsProfissional: row.fetch("cns"), codigoCbo2002: row.fetch("cbo"))

      def participant(klass, row)
        attrs = {
          cpfParticipante: row["cpf"], cnsParticipante: row["cns"], stCidadaoNaoPossuiCpf: row["no_cpf"],
          justificativaCidadaoNaoPossuiCpf: row["justification"], sexo: row.fetch("sex"),
          dataNascimento: RegistrationFields.epoch_ms(row.fetch("birth_date")), avaliacaoAlterada: row["altered_evaluation"] == true
        }
        row["measurements"].to_h.each do |key, value|
          name = CollectiveActivity::MEASUREMENTS[key]
          attrs[name.to_sym] = value.to_f if name && !value.nil?
        end
        row["smoking"].to_h.each do |key, value|
          name = CollectiveActivity::SMOKING[key]
          attrs[name] = value if name && [ true, false ].include?(value)
        end
        klass.new(**attrs)
      end
    end

    CollectiveActivity::SOURCE_TYPE = "CollectiveActivity".freeze
    CollectiveActivity::ORIGIN_THIRD_PARTY = 3
    # chave da medida do participante => campo do ParticipanteRowItemThrift (peso, altura: double).
    CollectiveActivity::MEASUREMENTS = YAML.load_file(Rails.root.join("config/ledi/visit_activity_dictionaries.yml"))
                                           .dig("collective_activity", "rules", "participant_measurements")
                                           .transform_values { |spec| spec.fetch("ledi").freeze }.freeze
    # Tabagismo do participante (só com as práticas 25–28; o Rules já recusa fora delas).
    CollectiveActivity::SMOKING = { "quit" => :cessouHabitoFumar, "dropped_out" => :abandonouGrupo }.freeze
  end
end
