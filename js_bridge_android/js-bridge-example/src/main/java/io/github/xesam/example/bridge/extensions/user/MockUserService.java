package io.github.xesam.example.bridge.extensions.user;

public final class MockUserService {
    public static final class User {
        private String id;
        private String name;

        public User(String id, String name) {
            this.id = id;
            this.name = name;
        }

        public String getId() {
            return id;
        }

        public String getName() {
            return name;
        }

        @Override
        public String toString() {
            return "User{" +
                    "id='" + id + '\'' +
                    ", name='" + name + '\'' +
                    '}';
        }
    }

    public interface UserServiceCallback {
        void onSuccess(User user);

        void onFail(Error error);
    }

    public void getUser(String userId, UserServiceCallback userServiceCallback) {
        new Thread() {
            @Override
            public void run() {
                try {
                    sleep(1000);
                    if (userId.equals("001")) {
                        userServiceCallback.onSuccess(new User(userId, "xesam"));
                    } else {
                        userServiceCallback.onFail(new Error("no such user:" + userId));
                    }

                } catch (InterruptedException e) {
                    userServiceCallback.onFail(new Error(e.getMessage()));
                }
            }
        }.start();
    }
}
