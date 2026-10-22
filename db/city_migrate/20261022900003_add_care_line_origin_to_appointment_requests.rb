# Módulo 23 (contrato §11 T4; ADR 0040): "Agendar" pela linha de cuidado abre
# um pedido do módulo 17 com origem na inscrição (kind care_line), sem
# triagem raiz. A origem continua única (atendimento, triagem OU inscrição);
# um pedido vivo por inscrição. A raiz só falta no pedido da linha ou no que
# nasce de um atendimento (o atendimento do horário da linha não tem raiz, e
# o retorno/encaminhamento/escuta dele herda isso); o pedido da triagem
# segue com raiz. Triggers em db/city_triggers.sql: a guarda congela a origem
# nova e rota_appointment_request_root_guard (INSERT) só aceita a raiz nula
# com origem num atendimento cuja cadeia também não tem raiz. Irreversível.
class AddCareLineOriginToAppointmentRequests < ActiveRecord::Migration[8.1]
  def up
    add_reference :appointment_requests, :origin_care_line_enrollment, type: :uuid, index: false,
                                                                       foreign_key: { to_table: :care_line_enrollments }
    add_index :appointment_requests, :origin_care_line_enrollment_id, unique: true,
              where: "origin_care_line_enrollment_id IS NOT NULL AND status::text = ANY (ARRAY['open'::text, 'scheduled'::text])",
              name: "idx_appointment_requests_one_live_care_line"
    change_column_null :appointment_requests, :root_triage_id, true
    remove_check_constraint :appointment_requests, name: "ck_appointment_requests_kind"
    remove_check_constraint :appointment_requests, name: "ck_appointment_requests_origin"
    add_check_constraint :appointment_requests,
                         "kind::text = ANY (ARRAY['return'::text, 'referral'::text, 'triage'::text, 'screening'::text, 'care_line'::text])",
                         name: "ck_appointment_requests_kind"
    add_check_constraint :appointment_requests, "num_nonnulls(origin_attendance_id, origin_triage_id, origin_care_line_enrollment_id) = 1",
                         name: "ck_appointment_requests_origin"
    add_check_constraint :appointment_requests,
                         "((kind)::text = 'care_line'::text) = (origin_care_line_enrollment_id IS NOT NULL) AND " \
                         "((kind)::text = 'care_line'::text OR origin_attendance_id IS NOT NULL OR root_triage_id IS NOT NULL) AND " \
                         "((kind)::text <> 'care_line'::text OR (origin_unit_id IS NOT NULL AND target_unit_id IS NOT NULL))",
                         name: "ck_appointment_requests_care_line"
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
