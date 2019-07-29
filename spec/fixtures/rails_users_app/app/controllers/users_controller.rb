class UsersController < ApplicationController
  def create
    @user = User.new(params.slice(:login).to_unsafe_h)
    unless @user.valid?
      error = {
        code: 'invalid',
        target: 'User',
        message: @user.errors.full_messages.join(', '),
        details: @user.errors.map { |k, v| { code: 'invalid', target: k, message: v.join(', ') } }
      }
      return render json: error, status: :unprocessable_entity
    end
    @user.save
    render json: @user, status: :created
  end
end