import {
    createClient,
    type SupabaseClient,
} from "@supabase/supabase-js";

let browserSupabase: SupabaseClient | null = null;

function getSupabaseClient(): SupabaseClient {
    if (browserSupabase) {
        return browserSupabase;
    }

    if (typeof window === "undefined") {
        throw new Error(
            "Supabase client is only available in the browser at runtime.",
        );
    }

    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL || "";
    const supabaseAnonKey =
        process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY || "";

    if (!supabaseUrl || !supabaseAnonKey) {
        throw new Error(
            "Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY.",
        );
    }

    browserSupabase = createClient(supabaseUrl, supabaseAnonKey);
    return browserSupabase;
}

export const supabase = new Proxy({} as SupabaseClient, {
    get(_target, prop, receiver) {
        return Reflect.get(getSupabaseClient(), prop, receiver);
    },
});
