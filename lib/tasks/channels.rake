namespace :channels do
  desc "Rotate a municipality's WhatsApp access_token. ENV: MUNICIPALITY_SLUG, ROTATE_TOKEN, ACTOR_EMAIL"
  task rotate_token: :environment do
    slug  = ENV.fetch("MUNICIPALITY_SLUG")
    token = ENV.fetch("ROTATE_TOKEN")
    actor = ApplicationRecord.connected_to(role: :admin) { User.find_by!(email_address: ENV.fetch("ACTOR_EMAIL")) }
    muni  = ApplicationRecord.connected_to(role: :admin) { Municipality.find_by!(slug: slug) }

    result = MunicipalityChannels::RotateToken.call(municipality_id: muni.id, new_token: token, by: actor)
    abort("[channels:rotate_token] failed: #{result.reason} #{result.message}") if result.failure?
    puts "[channels:rotate_token] rotated channel for #{slug} (phone_number_id=#{result.payload[:channel].phone_number_id})"
  end
end
