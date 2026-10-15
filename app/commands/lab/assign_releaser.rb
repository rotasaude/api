# Liga um liberador a um laboratório (contrato §3): papel lab_releaser,
# perfil com CRF/CRBM/CRM; um RT e um substituto ativos por laboratório.
module Lab
  module AssignReleaser
    module_function

    def call(user_id:, provider:, technical_lead:, technical_deputy:, by:)
      user = user_id.is_a?(String) && User.find_by(id: user_id, deactivated_at: nil)
      return Result.fail(:not_found) unless user
      return Result.fail(:user_missing_role) unless user.has_role?("lab_releaser")
      return Result.fail(:council_missing) unless Access.council(user)
      return Result.fail(:invalid_marks) unless [ true, false ].include?(technical_lead) && [ true, false ].include?(technical_deputy)
      return Result.fail(:invalid_marks) if technical_lead && technical_deputy

      releaser = LabReleaser.create!(user: user, exam_provider: provider, technical_lead: technical_lead,
                                     technical_deputy: technical_deputy, created_by_user: by)
      DomainEvents.publish("lab_releaser.assigned", lab_releaser_id: releaser.id, exam_provider_id: provider.id)
      Result.ok(releaser: releaser)
    rescue ActiveRecord::RecordNotUnique => e
      Result.fail({ "idx_lab_releasers_lead" => :lead_taken, "idx_lab_releasers_deputy" => :deputy_taken }
                    .find { |index, _| e.message.include?(index) }&.last || :already_assigned)
    end

    def end!(releaser:, by:)
      releaser.update!(ended_at: Time.current, ended_by_user: by)
      DomainEvents.publish("lab_releaser.ended", lab_releaser_id: releaser.id, exam_provider_id: releaser.exam_provider_id)
      Result.ok(releaser: releaser)
    end
  end
end
