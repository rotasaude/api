# Guia de encaminhamento da regulação municipal em PDF (ADR 0044; contrato §3,
# §13 G8, G10, G12, G14), para a unidade entregar ao paciente. Gerada na hora,
# nunca gravada. A folha, a fonte e o rodapé em toda página são os de
# Consultations::Print.document; o texto passa por Print.safe (a fonte
# embutida não tem todo símbolo). Blocos: cabeçalho (cidade, número curto = 8
# primeiros do id, data do pedido), paciente (nome, nascimento, sexo, CNS
# mascarado; NUNCA o CPF, só "sem CPF" quando não há), pedido (tipo, alvo pelo
# `target_name`, o código presente — CID-10 e/ou CIAP-2 — com a descrição da
# release ativa, justificativa, cor efetiva, prazo, número do estado),
# solicitante (nome profissional, CBO, unidade) e autorização (prestador, mês,
# agendamento) ou a situação. Rascunho sai com a marca "RASCUNHO — sem
# validade" (a rota não o serve). Nada vai a log.
require "prawn"

module CareRegulation
  module GuidePdf
    TITLE = "Guia de encaminhamento".freeze
    FOOTER_TEXT = "Gerado pelo Rota Saúde — guia de regulação municipal; não é autorização do sistema do estado".freeze
    DRAFT_MARK = "RASCUNHO — sem validade".freeze
    NONE = "—".freeze
    # Consultations::Print.document só lê `footer.text`.
    Footer = Data.define(:text)
    TYPES = { "specialty" => "Especialidade", "procedure" => "Procedimento" }.freeze
    COLORS = { "red" => "Vermelho", "yellow" => "Amarelo", "green" => "Verde", "blue" => "Azul" }.freeze
    SEX = { "female" => "Feminino", "male" => "Masculino" }.freeze
    PROVIDER_KINDS = { "own" => "rede própria", "contracted" => "contratado", "consortium" => "consórcio", "ppi" => "PPI" }.freeze
    SYSTEMS = { "sisreg" => "SISREG", "care" => "CARE", "cross" => "CROSS", "other" => "Outro" }.freeze
    WAITING = "Aguardando regulação".freeze
    STATUS_TEXT = { "pending" => WAITING, "returned" => "Devolvido à unidade para complemento", "external" => "Regulado pelo estado",
                    "denied" => "Negado", "cancelled" => "Cancelado", "closed" => "Encerrado",
                    "authorized" => "Autorizado", "scheduled" => "Agendado", "completed" => "Realizado", "draft" => WAITING }.freeze
    DIAGNOSES = [ [ "cid10", "CID-10" ], [ "ciap2", "CIAP-2" ] ].freeze

    module_function

    # request: RegulationRequest -> String (bytes do PDF).
    def call(request)
      pdf = Consultations::Print.document(Footer.new(FOOTER_TEXT), title: TITLE)
      header(pdf, request)
      patient(pdf, request.patient)
      order(pdf, request)
      requester(pdf, request)
      authorization(pdf, request)
      pdf.number_pages "Página <page> de <total>", at: [ 0, -14 ], width: pdf.bounds.width, size: 7, align: :right
      pdf.render
    end

    def s(text) = Consultations::Print.safe(text)
    def date(value) = value&.strftime("%d/%m/%Y")

    def section(pdf, text)
      pdf.move_down 8
      pdf.text s(text), style: :bold, size: 11
      pdf.move_down 2
    end

    def field(pdf, label, value)
      pdf.formatted_text [ { text: s("#{label}: "), styles: [ :bold ] }, { text: s(value.presence || NONE) } ]
    end

    def header(pdf, request)
      pdf.text s(CityProfile.current&.name.to_s), style: :bold, size: 12
      pdf.text s(TITLE), style: :bold, size: 14
      pdf.text s(DRAFT_MARK), style: :bold, size: 12 if request.status == "draft"
      pdf.text s("Nº #{request.id[0, 8]}"), style: :bold
      field(pdf, "Data do pedido", date((request.requested_at || request.created_at).in_time_zone))
    end

    def patient(pdf, patient)
      section(pdf, "Paciente")
      field(pdf, "Nome", patient.display_name)
      birth = patient.birth_date.present? ? Date.iso8601(patient.birth_date).strftime("%d/%m/%Y") : nil
      field(pdf, "Nascimento", birth || "não informado")
      field(pdf, "Sexo", SEX.fetch(patient.sex.to_s, "não informado"))
      field(pdf, "CNS", patient.cns_masked) if patient.cns.present?
      field(pdf, "CPF", "sem CPF") unless patient.cpf.present?
    end

    def order(pdf, r)
      section(pdf, "Pedido")
      field(pdf, "Tipo", TYPES.fetch(r.target_type, r.target_type))
      field(pdf, "Alvo", "#{r.target_code} — #{r.target_name}")
      DIAGNOSES.each do |terminology, label|
        code = r.public_send(terminology)
        field(pdf, label, [ code, ClinicalTerms.find(terminology, code)&.label ].compact_blank.join(" — ")) if code.present?
      end
      field(pdf, "Justificativa", r.justification)
      color = COLORS.fetch(r.effective_color, r.effective_color)
      field(pdf, "Prioridade", r.color ? color : "#{color} (sugerida, ainda não confirmada pela regulação)")
      field(pdf, "Prazo", date(r.due_on))
      return unless r.state_regulated

      field(pdf, "Regulação", "regulado pelo estado")
      field(pdf, "Número no sistema do estado", [ SYSTEMS.fetch(r.external_system.to_s, nil), r.external_number ].compact.join(" ")) if r.external_number
    end

    def requester(pdf, r)
      section(pdf, "Solicitante")
      field(pdf, "Nome", Screenings::Json.staff_name(r.requester_user))
      field(pdf, "CBO", "#{r.requester_cbo} #{Professionals::Cbo.find(r.requester_cbo)&.title}".strip)
      unit = r.requester_unit
      field(pdf, "Unidade", [ unit.name, (unit.cnes ? "CNES #{unit.cnes}" : nil) ].compact.join(" — "))
    end

    def authorization(pdf, r)
      section(pdf, "Autorização")
      found = Json.authorization(r)
      if found
        provider = found.fetch(:provider)
        cnes = CareProvider.find_by(id: provider.fetch(:id))&.cnes
        field(pdf, "Prestador", [ provider.fetch(:name), (cnes ? "CNES #{cnes}" : nil), PROVIDER_KINDS[provider.fetch(:kind)] ].compact.join(" — "))
        field(pdf, "Mês autorizado", found.fetch(:month).split("-").reverse.join("/"))
      else
        field(pdf, "Situação", STATUS_TEXT.fetch(r.status, WAITING))
      end
      return unless r.scheduled_at

      field(pdf, "Agendamento", r.scheduled_at.in_time_zone.strftime("%d/%m/%Y %H:%M"))
      field(pdf, "Local", r.schedule_place)
    end
    private_class_method :s, :date, :section, :field, :header, :patient, :order, :requester, :authorization
  end
end
