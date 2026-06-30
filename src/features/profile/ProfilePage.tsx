import { useRef, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { Camera, KeyRound, Loader2, Mail, Phone, ShieldCheck, Trash2 } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { toast } from "@/components/ui/use-toast";
import { formatDateTime } from "@/lib/utils";
import { useSession } from "@/lib/auth/session";
import { ROLE_LABELS } from "@/lib/data/types";
import { Avatar } from "@/layouts/HeaderControls";
import { useUpdateUser } from "@/features/users/hooks";
import { isSupabaseConfigured, supabase } from "@/lib/supabase/client";
import { updateOwnProfile } from "@/lib/supabase/profile";

export function ProfilePage() {
  const user = useSession((s) => s.user)!;
  const setUser = useSession((s) => s.setUser);
  const [params, setParams] = useSearchParams();
  const tab = params.get("tab") ?? "profile";
  const updateMut = useUpdateUser();

  const setTab = (t: string) => setParams(t === "profile" ? {} : { tab: t }, { replace: true });

  // ── Profile form ──────────────────────────────────────────────────────
  const [name, setName] = useState(user.name);
  const [phone, setPhone] = useState(user.phone ?? "");
  const [avatar, setAvatar] = useState<string | null>(user.avatar_url ?? null);
  const [saving, setSaving] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  /** True only when a real Supabase auth session exists — a seeded/mock user
   *  (even with Supabase configured) must save via the mock repo, otherwise the
   *  self-edit RPC runs with auth.uid()=null and fails silently. */
  const hasSupabaseSession = async () =>
    isSupabaseConfigured && supabase ? !!(await supabase.auth.getSession()).data.session : false;
  const dirty = name !== user.name || phone !== (user.phone ?? "") || avatar !== (user.avatar_url ?? null);

  const onPickAvatar = (file: File | undefined) => {
    if (!file) return;
    if (file.size > 1_000_000) {
      toast.error("Image too large", "Please choose an image under 1 MB.");
      return;
    }
    const reader = new FileReader();
    reader.onload = () => setAvatar(reader.result as string);
    reader.readAsDataURL(file);
  };

  const saveProfile = async () => {
    if (!name.trim()) {
      toast.error("Name is required");
      return;
    }
    setSaving(true);
    try {
      const patch = { name: name.trim(), phone: phone.trim() || null, avatar_url: avatar };
      const updated = (await hasSupabaseSession())
        ? await updateOwnProfile(user.id, patch)
        : await updateMut.mutateAsync({ id: user.id, patch });
      setUser(updated);
      toast.success("Profile updated");
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Update failed");
    } finally {
      setSaving(false);
    }
  };

  // ── Password form ─────────────────────────────────────────────────────
  const [pw, setPw] = useState("");
  const [pw2, setPw2] = useState("");
  const pwError =
    pw.length > 0 && pw.length < 8
      ? "Password must be at least 8 characters"
      : pw2.length > 0 && pw !== pw2
        ? "Passwords do not match"
        : null;

  const savePassword = async () => {
    if (pw.length < 8 || pw !== pw2) {
      toast.error("Please fix the password fields");
      return;
    }
    try {
      if (await hasSupabaseSession()) {
        const { error } = await supabase!.auth.updateUser({ password: pw });
        if (error) throw new Error(error.message);
      } else {
        await updateMut.mutateAsync({ id: user.id, patch: { password: pw } });
      }
      setPw("");
      setPw2("");
      toast.success("Password changed");
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Change failed");
    }
  };

  return (
    <>
      <PageHeader title="My Profile" description="Manage your account details, password, and preferences." />

      <Tabs value={tab} onValueChange={setTab}>
        <TabsList>
          <TabsTrigger value="profile">Profile</TabsTrigger>
          <TabsTrigger value="password">Password</TabsTrigger>
        </TabsList>

        {/* ── Profile ─────────────────────────────────────────────────── */}
        <TabsContent value="profile">
          <div className="grid gap-4 lg:grid-cols-3">
            <Card className="p-6 lg:col-span-2">
              <div className="mb-5 flex items-center gap-4">
                <div className="relative">
                  <Avatar user={{ ...user, avatar_url: avatar }} className="h-16 w-16 text-lg" />
                  <button
                    onClick={() => fileRef.current?.click()}
                    className="absolute -bottom-1 -right-1 flex h-7 w-7 items-center justify-center rounded-full border bg-background shadow-sm hover:bg-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
                    aria-label="Change avatar"
                  >
                    <Camera className="h-3.5 w-3.5" />
                  </button>
                  <input
                    ref={fileRef}
                    type="file"
                    accept="image/*"
                    className="hidden"
                    onChange={(e) => onPickAvatar(e.target.files?.[0])}
                  />
                </div>
                <div>
                  <p className="text-lg font-semibold">{user.name}</p>
                  <Badge variant="outline" className="mt-1">{ROLE_LABELS[user.role]}</Badge>
                </div>
                {avatar && (
                  <Button variant="ghost" size="sm" className="ml-auto text-muted-foreground" onClick={() => setAvatar(null)}>
                    <Trash2 className="h-4 w-4" /> Remove
                  </Button>
                )}
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-1.5">
                  <Label>Full Name</Label>
                  <Input value={name} onChange={(e) => setName(e.target.value)} />
                </div>
                <div className="space-y-1.5">
                  <Label>Phone</Label>
                  <Input value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="Optional" />
                </div>
                <div className="space-y-1.5 sm:col-span-2">
                  <Label>Email</Label>
                  <Input value={user.email} disabled />
                  <p className="text-xs text-muted-foreground">Email changes are managed by an admin.</p>
                </div>
              </div>

              <div className="mt-5 flex justify-end">
                <Button variant="accent" onClick={saveProfile} disabled={!dirty || saving}>
                  {saving && <Loader2 className="h-4 w-4 animate-spin" />}
                  Save Changes
                </Button>
              </div>
            </Card>

            <Card className="h-fit p-6">
              <p className="mb-3 text-sm font-semibold">Account</p>
              <dl className="space-y-3 text-sm">
                <InfoRow icon={<Mail className="h-4 w-4" />} label="Email" value={user.email} />
                <InfoRow icon={<Phone className="h-4 w-4" />} label="Phone" value={user.phone || "—"} />
                <InfoRow icon={<ShieldCheck className="h-4 w-4" />} label="Role" value={ROLE_LABELS[user.role]} />
                <InfoRow label="Last Login" value={user.last_login ? formatDateTime(user.last_login) : "This session"} />
                <InfoRow label="Account Created" value={formatDateTime(user.created_at)} />
              </dl>
            </Card>
          </div>
        </TabsContent>

        {/* ── Password ────────────────────────────────────────────────── */}
        <TabsContent value="password">
          <Card className="max-w-md p-6">
            <div className="mb-4 flex items-center gap-2">
              <KeyRound className="h-5 w-5 text-muted-foreground" />
              <p className="text-sm font-semibold">Change Password</p>
            </div>
            <div className="space-y-4">
              <div className="space-y-1.5">
                <Label>New Password</Label>
                <Input type="password" value={pw} onChange={(e) => setPw(e.target.value)} autoComplete="new-password" />
              </div>
              <div className="space-y-1.5">
                <Label>Confirm Password</Label>
                <Input type="password" value={pw2} onChange={(e) => setPw2(e.target.value)} autoComplete="new-password" />
              </div>
              {pwError && <p className="text-xs text-destructive">{pwError}</p>}
              <p className="text-xs text-muted-foreground">
                Use at least 8 characters. When Supabase auth is enabled, this updates your password securely.
              </p>
              <Button variant="accent" onClick={savePassword} disabled={!pw || !pw2 || !!pwError || updateMut.isPending}>
                {updateMut.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                Update Password
              </Button>
            </div>
          </Card>
        </TabsContent>

      </Tabs>
    </>
  );
}

function InfoRow({ icon, label, value }: { icon?: React.ReactNode; label: string; value: string }) {
  return (
    <div className="flex items-start justify-between gap-3">
      <dt className="flex items-center gap-2 text-muted-foreground">
        {icon}
        {label}
      </dt>
      <dd className="text-right font-medium">{value}</dd>
    </div>
  );
}

