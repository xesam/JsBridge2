package io.github.xesam.example.bridge;

import android.content.Intent;
import android.os.Bundle;

import androidx.activity.EdgeToEdge;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;

import io.github.xesam.example.bridge.databinding.ActivityPickInputBinding;


public class PickInputActivity extends AppCompatActivity {
    private ActivityPickInputBinding mActivitySecondBinding;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        EdgeToEdge.enable(this);
        mActivitySecondBinding = ActivityPickInputBinding.inflate(getLayoutInflater());
        setContentView(mActivitySecondBinding.getRoot());
        ViewCompat.setOnApplyWindowInsetsListener(mActivitySecondBinding.getRoot(), (v, insets) -> {
            Insets systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars());
            v.setPadding(systemBars.left, systemBars.top, systemBars.right, systemBars.bottom);
            return insets;
        });
        mActivitySecondBinding.submit.setOnClickListener(view -> {
            Intent intent = new Intent();
            intent.putExtra("name", mActivitySecondBinding.name.getText().toString());
            intent.putExtra("age", Integer.parseInt(mActivitySecondBinding.age.getText().toString()));
            setResult(RESULT_OK, intent);
            finish();
        });

        Intent launchIntent = getIntent();

    }
}