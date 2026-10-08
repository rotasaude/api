require "rails_helper"

# Review Focus 1 (ADR 0031; Desvio 4): a rotação de chave da cidade regrava o
# texto cifrado da consulta finalizada, do adendo e da nota de abertura sem
# esbarrar na imutabilidade — e o conteúdo continua legível.
RSpec.describe "Re-cifra do prontuário" do
  let(:old_material) { "0" * 64 }

  let!(:city) { clinical_city! }

  def in_city(&) = CityConnection.with(city) { Current.set(city: city, &) }

  # Material arbitrário (a chave "antiga"), como em spec/commands/city_rekey_spec.rb.
  def with_material(material, &block)
    other = City.new(slug: city.slug, name: city.name, status: city.status,
                     database_url: city.database_url, encryption_key: material)
    CityConnection.with(city) do
      Current.set(city: other) do
        ActiveRecord::Encryption.with_encryption_context(**CityEncryption.context_properties(other), &block)
      end
    end
  end

  def call_job_body(**kwargs)
    ReencryptionJob.instance_method(:perform).super_method.bind_call(ReencryptionJob.new, **kwargs)
  end

  def raw(table, column, id)
    connection = ApplicationRecord.connection
    connection.select_value("SELECT #{column} FROM #{table} WHERE id = #{connection.quote(id)}")
  end

  # Paciente, consulta finalizada com S/O/A/P, adendo e abertura com nota.
  def clinical_rows!
    ciap2_release!
    unit = create_unit
    doctor = doctor!(unit)
    citizen = verified_citizen!(1)
    patient = Patient.create!(cpf: citizen.cpf, full_name: "Maria Aparecida da Silva")
    link = doctor.professional.links.active.sole
    consultation = Consultation.create!(attendance: consulting_attendance!(unit, citizen: citizen, doctor: doctor),
                                        patient: patient, author_user: doctor, professional_link: link, cbo_code: link.cbo_code,
                                        status: "draft", started_at: Time.current, subjective: "texto S", objective: "texto O",
                                        assessment: "texto A", plan: "texto P")
    consultation.update!(status: "finalized", finalized_at: Time.current, care_type: 5)
    addendum = ConsultationAddendum.create!(consultation: consultation, author_user: doctor, text: "texto do adendo",
                                            reason: "acréscimo de informação")
    now = Time.current
    opening = ClinicalRecordOpening.create!(patient: patient, user: doctor, reason_code: "other",
                                            reason_note: "revisão pedida pela coordenação", created_at: now, expires_at: now + 30.minutes)
    { patient: patient, cpf: citizen.cpf, consultation: consultation, addendum: addendum, opening: opening }
  end

  # Tudo da consulta menos o texto cifrado (sem decifrar: pluck das colunas claras).
  def consultation_plain_columns(id)
    Consultation.where(id: id).pluck(*(Consultation.column_names - Consultation::TEXT_FIELDS)).sole
  end

  def expect_readable(rows)
    expect(Consultation.find(rows[:consultation].id).slice(:subjective, :objective, :assessment, :plan))
      .to eq("subjective" => "texto S", "objective" => "texto O", "assessment" => "texto A", "plan" => "texto P")
    expect(ConsultationAddendum.find(rows[:addendum].id).text).to eq("texto do adendo")
    expect(ClinicalRecordOpening.find(rows[:opening].id).reason_note).to eq("revisão pedida pela coordenação")
    expect(Patient.where(cpf: rows[:cpf]).pluck(:id)).to eq([ rows[:patient].id ])
  end

  describe "ReencryptionJob (chave atual da cidade)" do
    let!(:rows) { in_city { clinical_rows! } }

    it "regrava sob a marca e o texto continua o mesmo" do
      before = in_city { raw("consultations", "subjective", rows[:consultation].id) }
      stats = in_city { call_job_body(only: %i[consultation consultation_addendum clinical_record_opening patient]) }
      expect(stats).to include("Consultation" => 1, "ConsultationAddendum" => 1, "ClinicalRecordOpening" => 1, "Patient" => 1)
      in_city do
        expect(raw("consultations", "subjective", rows[:consultation].id)).not_to eq(before)
        expect_readable(rows)
        expect(rows[:consultation].reload).to be_finalized
      end
    end

    it "sem a marca, a consulta finalizada continua recusando a regravação" do
      in_city do
        expect { ApplicationRecord.transaction(requires_new: true) { rows[:consultation].encrypt } }
          .to raise_error(ActiveRecord::StatementInvalid, /finalized consultation never changes/)
        expect { ApplicationRecord.transaction(requires_new: true) { rows[:addendum].encrypt } }
          .to raise_error(ActiveRecord::StatementInvalid, /UPDATE refused/)
      end
    end
  end

  describe "CityRekey (material antigo → material da cidade)" do
    let!(:rows) { with_material(old_material) { clinical_rows! } }

    it "regrava tudo numa transação com a marca: legível com a chave nova, ilegível com a antiga" do
      before = in_city { consultation_plain_columns(rows[:consultation].id) }

      result = CityRekey.call(city: city, from_key: old_material)

      expect(result).to be_ok
      expect(result.payload[:counts]).to include("Consultation" => 4, "ConsultationAddendum" => 1, "ClinicalRecordOpening" => 1)
      expect(result.payload[:counts]["Patient"]).to be >= 2
      in_city do
        expect_readable(rows)
        expect(consultation_plain_columns(rows[:consultation].id)).to eq(before)
        expect(ApplicationRecord.connection.select_value("SELECT current_setting('rota.reencrypting', true)")).not_to eq("on")
        expect { ApplicationRecord.transaction(requires_new: true) { rows[:consultation].reload.update_columns(plan: "outro") } }
          .to raise_error(ActiveRecord::StatementInvalid, /finalized consultation never changes/)
      end
      with_material(old_material) do
        expect { Consultation.find(rows[:consultation].id).subjective }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
        expect { ConsultationAddendum.find(rows[:addendum].id).text }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
        expect { ClinicalRecordOpening.find(rows[:opening].id).reason_note }
          .to raise_error(ActiveRecord::Encryption::Errors::Decryption)
        expect(Patient.where(cpf: rows[:cpf]).count).to eq(0)
      end
    end
  end
end
