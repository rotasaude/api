# Registra a atividade coletiva inteira, numa escrita só (módulo 24b, ADR
# 0052; contrato §1, §2, §4, §5, §7, §11, §13; Q15, Q32, Q38, Q41, Q42, Q49;
# plano, Task 13; pre-flight "| 13 |"). Sem rascunho, sem edição.
#
# 1. `client_uuid` já gravado pelo mesmo usuário → ok(replayed: true) com a
#    gravada; de outro usuário → client_uuid_conflict (nunca mostra a alheia).
# 2. Regras puras do §4 (CollectiveActivities::Rules, dirigidas pelo YAML)
#    sobre o corpo plano (Q15) — antes de tudo, inclusive do acesso: um corpo
#    malformado é 422 com path, nunca 403 por um campo.
# 3. Acesso pela Tabela 5 (CollectiveActivities::Access): sem vínculo ativo na
#    equipe → out_of_scope; CBO do vínculo fora da Tabela 5 → cbo_not_allowed.
# 4. Transação própria (savepoint `requires_new`: dentro do envio do app, a
#    recusa desfaz só o item). Travas: pacientes citados por id FOR UPDATE, em
#    ordem de id; a atividade é nova (o índice único do client_uuid serializa
#    o replay). Na ordem, antes de qualquer escrita: unidade do local ativa com
#    CNES (path place_health_unit_id); profissionais com vínculo ativo em
#    qualquer equipe ativa e CNS válido (professional_without_cns), o CBO do
#    vínculo (o da equipe da atividade, se houver); participantes existentes
#    pela guarda do HomeVisits::People (not_found, patient_unidentified).
# 5. Só então as escritas: pacientes novos (People.resolve, savepoint próprio;
#    a recusa de um desfaz o item inteiro, Q15, Q49; o candidato que é o
#    paciente criado por outro participante → duplicate_participant, nunca
#    na trilha, Ruling T13-DUP), a atividade (altered_count
#    derivado da lista, Q38), profissionais e participantes (o trigger da T4 só
#    os aceita nesta transação), a ficha 6 pela fonte "CollectiveActivity"
#    (Ledi::FichaSources; Ledi::CollectiveActivityFicha, Task 14) e o evento
#    collective_activity.recorded só com ids.
#
# Participante sem CPF e sem CNS não é recusado: nos tipos 5/6 a ficha fica
# "não gerada" participant_without_identifier; nos outros vai sem identificação
# (§11, Q42; Task 14). A trilha dos candidatos do duplicado suspeito é gravada
# DEPOIS da transação, com qualquer desfecho (People.candidates_viewed!).
# Tema, público, prática, procedimento, avaliação, medida, local, nome e
# documento nunca em Result.details, log ou evento.
module CollectiveActivities
  module Record
    EVENT = "collective_activity.recorded".freeze
    SOURCE_TYPE = "CollectiveActivity".freeze
    UUID = Rules::UUID

    # Desfaz o savepoint levando a recusa para fora.
    class Refused < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super(result.reason.to_s)
      end
    end

    module_function

    # -> Result.ok(activity:, replayed:) | Result.fail(<código>, details: { path: } ...)
    def call(params:, by:, origin: "dashboard", device: nil, trail: Trail)
      raise ArgumentError, "origin" unless HomeVisits::Catalog::ORIGINS.include?(origin)
      raise ArgumentError, "device: só (e sempre) com origin field_app" if (origin == "field_app") == device.nil?

      params = params.to_h.deep_stringify_keys
      uuid = params["client_uuid"]
      return refuse(:invalid_request, "client_uuid") unless uuid.is_a?(String) && uuid.match?(UUID)

      replay = replayed(uuid, by)
      return replay if replay

      error = Rules.check(params, today: Time.zone.today).first
      return refuse(error[:error], error[:path]) if error

      team = HealthTeam.find_by(id: params["team_id"])
      member = TerritoryRegistry::Access.membership(by, team)
      return Result.fail(:out_of_scope) unless member
      return Result.fail(:cbo_not_allowed) unless Access.registers?(by, team)

      shown = []
      result = begin
        ApplicationRecord.transaction(requires_new: true) { write(params, by, team, member, origin, device, shown) }
      rescue Refused => e
        e.result
      rescue ActiveRecord::RecordNotUnique => e
        raise unless e.message.include?("idx_collective_activities_client_uuid")

        replayed(uuid, by) || raise
      end
      HomeVisits::People.candidates_viewed!(candidate_ids: shown, by: by, trail: trail) if shown.any?
      result
    end

    def write(input, by, team, member, origin, device, shown)
      participants = Rules.list(input["participants"])
      lock_patients!(participants)
      place_unit!(input["place_health_unit_id"])
      colleagues = professionals!(Rules.list(input["professionals"]), by, team)
      existing = existing_patients!(participants, by)

      created = []
      patients = participants.each_with_index.map do |item, index|
        existing[index] || new_patient!(item, index, by, shown, created)
      end
      # O Rules já recusou a mesma pessoa duas vezes pelo corpo; aqui, o mesmo
      # paciente por caminhos diferentes (o patient_client_uuid do envio do
      # app, Task 20).
      ids = patients.map(&:id)
      repeated = ids.each_index.find { |index| ids.index(ids[index]) != index }
      refuse!(refuse(:duplicate_participant, "participants[#{repeated}]")) if repeated

      activity = insert!(input, by, team, member, origin, device, participants)
      colleagues.each do |professional, cbo|
        CollectiveActivityProfessional.create!(collective_activity: activity, professional: professional, cbo: cbo)
      end
      participants.zip(patients).each do |item, patient|
        CollectiveActivityParticipant.create!(
          collective_activity: activity, patient: patient, altered_evaluation: item["altered_evaluation"] == true,
          measurements: Rules.measurements(item["measurements"]), smoking: Rules.smoking(item["smoking"])
        )
      end
      Ledi::FichaSources.for(SOURCE_TYPE).generate(activity)
      DomainEvents.publish(EVENT, collective_activity_id: activity.id, user_id: by.id)
      Result.ok(activity: activity, replayed: false)
    end

    def replayed(uuid, by)
      activity = CollectiveActivity.find_by(client_uuid: uuid)
      return nil unless activity
      return refuse(:client_uuid_conflict, "client_uuid") unless by && activity.recorded_by_user_id == by.id

      Result.ok(activity: activity, replayed: true)
    end

    # FOR UPDATE em ordem de id (duas gravações com os mesmos pacientes sem deadlock).
    def lock_patients!(participants)
      ids = participants.filter_map { |item| item["patient_id"] }.uniq
      Patient.where(id: ids).order(:id).lock.pluck(:id) if ids.any?
    end

    # Unidade do local: ativa e com CNES (vai ao cnesLocalAtividade, §11).
    def place_unit!(id)
      return if id.nil?

      unit = HealthUnit.find_by(id: id)
      refuse!(refuse(:not_found, "place_health_unit_id")) unless unit
      refuse!(refuse(:invalid_collective_activity, "place_health_unit_id")) unless unit.active && unit.cnes.present?
    end

    # -> [[professional, cbo]]: vínculo ativo em qualquer equipe ativa da
    # cidade (o da equipe da atividade primeiro) e CNS válido. Quem registra
    # já é o cabeçalho e não entra na lista.
    def professionals!(items, by, team)
      items.each_with_index.map do |item, index|
        path = "professionals[#{index}].professional_id"
        id = item["professional_id"]
        refuse!(refuse(:invalid_collective_activity, path)) if id == by.professional&.id

        member = HealthTeamMember.active.joins(:health_team).where(professional_id: id, health_teams: { active: true })
                                 .order(Arel.sql(HealthTeamMember.sanitize_sql_array([ "health_team_id = ? DESC", team.id ])), :created_at, :id)
                                 .first
        refuse!(refuse(:not_found, path)) unless member
        professional = member.professional
        refuse!(refuse(:professional_without_cns, path)) unless Professionals::Cns.valid?(professional.cns)

        [ professional, member.cbo_code ]
      end
    end

    # { índice => paciente } dos participantes por patient_id, pela guarda do
    # People (not_found, patient_unidentified; Q41).
    def existing_patients!(participants, by)
      participants.each_with_index.with_object({}) do |(item, index), found|
        next if item["patient_id"].nil?

        resolved = HomeVisits::People.resolve(by: by, patient_id: item["patient_id"], path_prefix: "participants[#{index}]")
        refuse!(resolved) if resolved.failure?
        found[index] = resolved.payload[:patient]
      end
    end

    # `created`: os pacientes novos desta escrita. O Patients::Duplicates de
    # um participante vê, dentro da transação, o paciente que outro acabou de
    # criar: candidato que some no rollback. Então é a mesma pessoa duas vezes
    # (duplicate_participant, Ruling T13-DUP), e nenhum id criado aqui vai a
    # `candidates` nem à trilha.
    def new_patient!(item, index, by, shown, created)
      resolved = HomeVisits::People.resolve(by: by, new_patient: item["new_patient"], reviewed: item["duplicates_reviewed"],
                                            path_prefix: "participants[#{index}]")
      if resolved.ok?
        created << resolved.payload[:patient].id
        return resolved.payload[:patient]
      end

      candidate_ids = Array(resolved.details[:candidate_ids])
      refuse!(refuse(:duplicate_participant, "participants[#{index}]")) if candidate_ids.intersect?(created)

      shown.concat(candidate_ids)
      refuse!(Result.fail(resolved.reason, details: resolved.details.except(:candidate_ids)))
    end

    def insert!(input, by, team, member, origin, device, participants)
      CollectiveActivity.create!(
        client_uuid: input["client_uuid"], team: team, health_unit_id: team.health_unit_id, professional: by.professional,
        cbo: member.cbo_code, recorded_by_user: by, held_on: Rules.held_on(input["held_on"]), shift: input["shift"],
        activity_type: input["activity_type"], place_health_unit_id: input["place_health_unit_id"],
        place_text: Rules.place_text(input["place_text"]), participants_count: input["participants_count"],
        altered_count: Rules.altered_count(participants),
        **Rules::LISTS.to_h { |field| [ field.to_sym, Rules.list(input[field]) ] },
        procedure_code: input["procedure_code"], origin: origin, field_device_id: device&.id
      )
    end

    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    def refuse!(result) = raise(Refused, result)
    private_class_method :write, :replayed, :lock_patients!, :place_unit!, :professionals!, :existing_patients!, :new_patient!,
                         :insert!, :refuse, :refuse!
  end
end
