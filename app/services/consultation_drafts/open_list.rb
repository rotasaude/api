# Rascunhos de consulta abertos na cidade (card rotasaude/api#51), para o admin
# municipal achar o órfão: mais antigos primeiro, até Consultation::LIST_LIMIT.
# Por linha só ids, unidade, autora (e se ela ainda tem vínculo ativo na
# unidade do atendimento), as INICIAIS do paciente e as datas — nunca texto
# clínico, draft_items, nome ou CPF. Também a CONTAGEM de documentos clínicos
# emitidos (não cancelados) ligados ao rascunho: eles continuam valendo depois
# do descarte e o admin precisa ser avisado — só o número, nenhum conteúdo. Sem trilha de leitura: não há conteúdo
# clínico aqui.
module ConsultationDrafts
  module OpenList
    module_function

    def call
      drafts = Consultation.where(status: "draft").includes(:patient, author_user: :professional, attendance: :health_unit)
                           .order(:started_at, :id).limit(Consultation::LIST_LIMIT).to_a
      linked = ProfessionalLink.active.joins(:professional)
                               .where(professionals: { user_id: drafts.map(&:author_user_id).uniq })
                               .pluck("professionals.user_id", :health_unit_id).to_set
      # Uma consulta agrupada para a página inteira (sem N+1); cancelado não conta.
      issued = ClinicalDocument.where(consultation_id: drafts.map(&:id), status: "issued").group(:consultation_id).count
      drafts.map { |c| row(c, linked, issued.fetch(c.id, 0)) }
    end

    def row(c, linked, issued_documents)
      unit = c.attendance.health_unit
      { consultation_id: c.id, attendance_id: c.attendance_id, health_unit: { id: unit.id, name: unit.name },
        author: { user_id: c.author_user_id, name: Screenings::Json.staff_name(c.author_user) },
        author_linked: linked.include?([ c.author_user_id, unit.id ]),
        patient_initials: Patients::Initials.call(c.patient.display_name), issued_documents: issued_documents,
        started_at: c.started_at.iso8601, last_saved_at: c.updated_at.iso8601 }
    end
    private_class_method :row
  end
end
