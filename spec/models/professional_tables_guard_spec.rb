require "rails_helper"

# Módulo 10 (ADR 0021): vínculo e turno só aceitam acréscimo; o banco recusa
# por SQL direto, sem passar pelo modelo.
RSpec.describe "Guardas das tabelas de profissionais" do
  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:user) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:unit) { create_unit }
  let(:professional) do
    Professional.create!(user: user, professional_name: "Helena Duarte", council: "CRM", council_state: "PR",
                         registration_number: "12345", cns: "700000000000005")
  end
  let(:link) do
    ProfessionalLink.create!(professional: professional, health_unit: unit, cbo_code: "225125",
                             started_at: Time.current, started_by_user: admin)
  end

  # Savepoint por chamada: cada `sql` pode falhar de propósito — é o que estamos
  # testando —, e sem isolamento o erro do Postgres deixaria a transação da
  # fixture abortada para o resto do exemplo (nenhum comando novo é aceito até
  # ROLLBACK). Mesmo padrão de spec/models/membership_user_append_only_spec.rb.
  def sql(statement) = ApplicationRecord.transaction(requires_new: true) { ApplicationRecord.connection.execute(statement) }

  it "vínculo: DELETE recusado" do
    expect { sql("DELETE FROM professional_links WHERE id = '#{link.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "vínculo: mudar unidade, CBO ou início é recusado" do
    other = create_unit("UBS Outra")
    [ "health_unit_id = '#{other.id}'", "cbo_code = '225124'", "started_at = now() - interval '1 day'" ].each do |set|
      expect { sql("UPDATE professional_links SET #{set} WHERE id = '#{link.id}'") }
        .to raise_error(ActiveRecord::StatementInvalid, /only the ending columns/), set
    end
  end

  it "vínculo: encerra uma vez; a segunda é recusada" do
    # clock_timestamp(), não now(): now() é o instante de ABERTURA da transação
    # da fixture, que pode ser anterior ao started_at gravado com Time.current
    # (let de professional/link roda depois que a transação já começou) —
    # now() aqui poderia violar ck_professional_links_order por engano.
    sql("UPDATE professional_links SET ended_at = clock_timestamp(), ended_by_user_id = '#{admin.id}' WHERE id = '#{link.id}'")
    expect { sql("UPDATE professional_links SET ended_at = now() WHERE id = '#{link.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /already ended/)
  end

  it "vínculo: dois ativos iguais é recusado pelo índice parcial; encerrado não conta" do
    link
    expect do
      ProfessionalLink.create!(professional: professional, health_unit: unit, cbo_code: "225125",
                               started_at: Time.current, started_by_user: admin)
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  describe "turnos" do
    let(:shift) do
      ProfessionalShift.create!(professional_link: link, professional: professional, created_by_user: admin,
                                starts_at: 1.day.from_now.change(hour: 7), ends_at: 1.day.from_now.change(hour: 13))
    end

    it "DELETE recusado" do
      expect { sql("DELETE FROM professional_shifts WHERE id = '#{shift.id}'") }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    it "mudar horário é recusado; cancelar uma vez passa; a segunda é recusada" do
      expect { sql("UPDATE professional_shifts SET ends_at = ends_at + interval '1 hour' WHERE id = '#{shift.id}'") }
        .to raise_error(ActiveRecord::StatementInvalid, /only the cancellation columns/)
      sql("UPDATE professional_shifts SET cancelled_at = now(), cancelled_by_user_id = '#{admin.id}', " \
          "cancel_reason = 'troca' WHERE id = '#{shift.id}'")
      expect { sql("UPDATE professional_shifts SET cancel_reason = 'outra' WHERE id = '#{shift.id}'") }
        .to raise_error(ActiveRecord::StatementInvalid, /already cancelled/)
    end

    it "sobreposição do mesmo profissional é recusada; turno cancelado não conta" do
      shift
      overlapping = { professional_link: link, professional: professional, created_by_user: admin,
                      starts_at: shift.starts_at + 1.hour, ends_at: shift.ends_at + 1.hour }
      expect { ProfessionalShift.create!(overlapping) }.to raise_error(ActiveRecord::ExclusionViolation)
      shift.update!(cancelled_at: Time.current, cancelled_by_user: admin, cancel_reason: "troca")
      expect { ProfessionalShift.create!(overlapping) }.not_to raise_error
    end

    it "mais de 24h e fim antes do início são recusados pelo CHECK" do
      start = 1.day.from_now.change(hour: 7)
      [ [ start, start + 24.hours + 1.minute ], [ start, start - 1.hour ] ].each do |starts_at, ends_at|
        expect do
          ProfessionalShift.create!(professional_link: link, professional: professional, created_by_user: admin,
                                    starts_at: starts_at, ends_at: ends_at)
        end.to raise_error(ActiveRecord::StatementInvalid, /ck_professional_shifts_window/)
      end
    end

    it "turno com professional_id diferente do vínculo é recusado" do
      other_user = staff_with("outra@cidade.gov.br", "health_professional")
      other = Professional.create!(user: other_user, professional_name: "Outra", council: "CRM", council_state: "PR",
                                   registration_number: "54321", cns: "100000000000007")
      expect do
        ProfessionalShift.create!(professional_link: link, professional: other, created_by_user: admin,
                                  starts_at: 1.day.from_now, ends_at: 1.day.from_now + 2.hours)
      end.to raise_error(ActiveRecord::StatementInvalid, /must match the link/)
    end

    it "turno em vínculo encerrado é recusado pelo banco" do
      link.update!(ended_at: Time.current, ended_by_user: admin)
      expect { shift }.to raise_error(ActiveRecord::StatementInvalid, /link is ended/)
    end
  end
end
