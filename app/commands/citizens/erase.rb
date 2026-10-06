# ADR 0026 (spec §4.4): o municipal_admin confirma a exclusão (o step-up fica
# no controller). Numa transação só, com trava no pedido e nos pares do CPF:
# reconfere a retenção (atendimento chegado depois do pedido vira `retained`,
# nada mais muda); senão, para cada par, revoga, anonimiza, apaga o apagável e
# troca CPF e telefone por um marcador que não identifica ninguém.
# ADR 0028: também o CNS do CADSUS e a consulta pendente.
# Reasons: :not_pending, :own_request.
module Citizens
  module Erase
    TOMBSTONE_PREFIX = "erased:".freeze
    MAX_ATTEMPTS = 3

    # Um pedido do par mudou de unidade entre a trava das unidades e a dos pares.
    class UnitsChanged < StandardError; end

    module_function

    def call(request:, by:)
      attempts = 0
      begin
        attempt(request: request, by: by)
      rescue UnitsChanged
        attempts += 1
        raise if attempts >= MAX_ATTEMPTS

        request.reload
        retry
      end
    end

    def attempt(request:, by:)
      result = nil
      ApplicationRecord.transaction do
        request.lock!
        next result = Result.fail(:not_pending) unless request.status == "pending"
        next result = Result.fail(:own_request) if request.requested_by_user_id == by.id

        # Ordem global de travas: unidade FOR SHARE → cidadão → horários → pedido.
        # A exclusão escreve pedidos do par (nota do remarque, CloseRevoked) e
        # trava o cidadão em FOR UPDATE (segura a FK de um atendimento novo
        # enquanto reconfere a retenção). Sem a unidade na frente, cruzava com o
        # HealthUnits::Drain, que segura o pedido e espera o cidadão (FK do
        # pedido novo) — deadlock. Com a unidade em FOR SHARE, o Drain espera.
        locked_units = lock_units!(RequestErasure.pairs_of(request.cpf).order(:id).to_a)
        pairs = RequestErasure.pairs_of(request.cpf).order(:id).lock.to_a
        # Pares travados: nenhum pedido novo nasce para eles (FK). Se um pedido
        # entrou noutra unidade antes da trava, recomeça com ela na frente.
        raise UnitsChanged unless (unit_ids_of(pairs) - locked_units).empty?
        # O banco não exige decided_by_user: quem decide é gravado aqui, sempre.
        if RequestErasure.attended?(Citizen.where(id: pairs.map(&:id)))
          request.update!(status: "retained", decided_by_user: by, decided_at: Time.current)
          DomainEvents.publish("citizen.erasure_retained", request_id: request.id)
          next result = Result.ok(request: request)
        end

        pairs.each { |citizen| erase_pair(citizen) }
        # O trigger aceita a troca do cpf só nesta mesma UPDATE, mas não a
        # exige: o pedido confirmado deixa de guardar o CPF por causa daqui.
        request.update!(status: "confirmed", decided_by_user: by, decided_at: Time.current, cpf: tombstone)
        DomainEvents.publish("citizen.erased", request_id: request.id)
        result = Result.ok(request: request)
      end
      result
    end

    def erase_pair(citizen)
      phones = phone_variants(citizen.phone)

      # ADR 0029: o texto livre do remarque sai de todos os pedidos do par; dos vivos, ANTES da
      # revogação (que fecha os abertos).
      noted = AppointmentRequest.where(citizen_id: citizen.id).where.not(reschedule_note: nil)
      noted.live_requests.update_all(reschedule_note: nil, updated_at: Time.current)
      # No encerrado o trigger só aceita a nota indo a NULL, sem nenhuma outra
      # coluna junto (nem updated_at).
      noted.where(status: "closed").update_all(reschedule_note: nil)

      # Conversas do par: as dele (web) e as do WhatsApp do telefone, que não
      # têm citizen_id. Uma conversa web de OUTRO cidadão no mesmo celular (a
      # família) não é deste par e fica intacta.
      conversations = Conversation.where(citizen_id: citizen.id)
                                  .or(Conversation.where(citizen_id: nil, phone: phones))
      conversations.find_each do |conversation|
        RevokeConsent.call(conversation: conversation, origin: "erasure") if conversation.active_consent
        # Nenhuma triagem tem atendimento (reconferido acima, sob trava): todas
        # se limpam, sem a checagem de Triages::Anonymize.call.
        Triage.where(conversation_id: conversation.id).find_each { |t| Triages::Anonymize.clear!(t) }
        conversation.update_columns(phone: tombstone, updated_at: Time.current)
      end

      # Não há chave estrangeira nem trigger que segure estes DELETEs
      # (campaign_recipients_append_only deixa o DELETE passar de propósito).
      CitizenSession.where(phone: phones).delete_all
      OtpChallenge.where(phone: phones).delete_all
      InboundMessage.where(from: phones).delete_all
      OutboundMessage.where(to: phones).delete_all
      CitizenVerificationCode.where(citizen_id: citizen.id).delete_all
      CitizenContactPreference.where(citizen_id: citizen.id).delete_all
      CampaignRecipient.where(citizen_id: citizen.id).delete_all
      # ADR 0027 (spec 2026-10-05 §5.5): as sugestões do par (o trigger deixa o
      # DELETE passar de propósito).
      TriageSuggestion.where(citizen_id: citizen.id).delete_all
      # ADR 0029: os avisos de lembrete do par (o trigger deixa o DELETE passar).
      AppointmentNotice.where(citizen_id: citizen.id).delete_all

      # ADR 0028: o CNS do CADSUS, a marca e a consulta pendente saem junto.
      # update_columns cifra (o tipo cifrado serializa); um marcador por coluna,
      # para não repetir valor entre cpf e phone.
      citizen.update_columns(cpf: tombstone, phone: tombstone, neighborhood_id: nil, erased_at: Time.current,
                             birth_date: nil, sex: nil, gender_identity: nil, profile_source: nil,
                             cns: nil, cadsus_checked_at: nil, cadsus_pending_cns: nil,
                             cadsus_pending_session_id: nil, cadsus_pending_at: nil, updated_at: Time.current)
    end

    # Trava FOR SHARE (por id) as unidades dos pedidos que a exclusão vai
    # escrever, até o conjunto parar de mudar (um Drain que commitou enquanto
    # esperávamos levou o pedido para outra unidade). Devolve os ids travados.
    def lock_units!(pairs)
      locked = []
      loop do
        missing = unit_ids_of(pairs) - locked
        return locked if missing.empty?

        HealthUnit.where(id: missing).order(:id).lock("FOR SHARE").to_a
        locked += missing
      end
    end

    # Unidades dos pedidos vivos que erase_pair escreve: os do par (nota do
    # remarque) e os de triagem ligados às conversas do par (CloseRevoked).
    def unit_ids_of(pairs)
      return [] if pairs.empty?

      citizen_ids = pairs.map(&:id)
      phones = pairs.flat_map { |citizen| phone_variants(citizen.phone) }
      conversations = Conversation.where(citizen_id: citizen_ids).or(Conversation.where(citizen_id: nil, phone: phones))
      triage_ids = Triage.where(conversation_id: conversations.select(:id)).select(:id)
      linked = AppointmentRequestTriage.where(triage_id: triage_ids).select(:request_id)
      live = AppointmentRequest.live_requests
      live.where(citizen_id: citizen_ids).or(live.where(origin_triage_id: triage_ids)).or(live.where(id: linked))
          .where.not(target_unit_id: nil).distinct.pluck(:target_unit_id).sort
    end

    # O cadastro web guarda "+55…"; o WhatsApp grava o que a Meta manda, só
    # dígitos, sem "+". Os dois formatos são o mesmo telefone.
    def phone_variants(phone) = [ phone, phone.delete_prefix("+") ].uniq

    # Marcador sem identidade; também usado por RejectErasure.
    def tombstone = "#{TOMBSTONE_PREFIX}#{SecureRandom.uuid}"
  end
end
